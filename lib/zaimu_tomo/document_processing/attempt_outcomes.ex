defmodule ZaimuTomo.DocumentProcessing.AttemptOutcomes do
  @moduledoc """
  Records what happened to an OCR attempt once Oban has settled it, and tells
  the document owner's open pages.

  A failed attempt with a retry ahead (`[:oban, :job, :exception]` with
  `state: :failure`) stores its failure code in the job's `meta["last_error"]`,
  where `Run` reads it, and then broadcasts `:attempt_failed`. `failure_code/1`
  derives the code from the exception Oban reports, never from its message. A
  final attempt is not handled here, because `OCRJob` records it and broadcasts
  `:failed`.

  Oban emits the event after it has written the job's `retryable` state, so a
  page that re-reads the job on the broadcast sees the attempt that failed and
  its code. The handler runs in the job's process, or for a timeout or crash in
  the task Oban starts to report it, so its database writes delay only that
  process.
  """

  import Ecto.Query

  require Logger

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @handler_id "zaimu-tomo-ocr-attempt-outcomes"
  @events [[:oban, :job, :exception]]
  @worker inspect(OCRJob)

  @doc """
  Attaches the handler to Oban's job events. Safe to call repeatedly.
  """
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  The failure code of an attempt, from the exception Oban reports for it.

  An `{:error, code}` return keeps its code, which `OCRJob` takes from
  `ErrorClassification.summarize/1`. `Oban.TimeoutError` is `"job_timeout"`.
  A raise, an exit, or a crash is `"unclassified"`.
  """
  @spec failure_code(term()) :: String.t()
  def failure_code(%Oban.PerformError{reason: {:error, code}}) when is_binary(code), do: code
  def failure_code(%Oban.TimeoutError{}), do: "job_timeout"
  def failure_code(_reason), do: "unclassified"

  @doc false
  def handle_event(event, _measurements, meta, _config) do
    handle(event, meta)
  rescue
    # :telemetry detaches a handler that raises, which would end these
    # outcomes until the next restart.
    error -> Logger.warning("[OCR] Attempt outcome not handled: #{inspect(error.__struct__)}")
  end

  defp handle(
         [:oban, :job, :exception],
         %{state: :failure, job: %Oban.Job{worker: @worker} = job} = meta
       ) do
    retrying(meta.conf, job, failure_code(meta.reason))
  end

  defp handle(_event, _meta), do: :ok

  defp retrying(conf, %Oban.Job{args: %{"document_id" => id}} = job, code) do
    case Oban.update_job(conf.name, job, %{meta: Map.put(job.meta, "last_error", code)}) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[OCR] Could not store the last error of job #{job.id}: #{inspect(reason)}"
        )
    end

    notify(:attempt_failed, id)
  end

  defp notify(kind, document_id) do
    case Repo.one(from d in Document, where: d.id == ^document_id, select: d.user_id) do
      nil ->
        :ok

      user_id ->
        DocumentProcessing.broadcast_event(kind, user_id, %{
          document_id: document_id,
          user_id: user_id,
          status: kind
        })
    end
  end
end
