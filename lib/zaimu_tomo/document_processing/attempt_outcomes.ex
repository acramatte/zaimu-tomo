defmodule ZaimuTomo.DocumentProcessing.AttemptOutcomes do
  @moduledoc """
  Records what happened to an OCR attempt once Oban has settled it, and tells
  the document owner's open pages.

    * A failed attempt with a retry ahead (`[:oban, :job, :exception]` with
      `state: :failure`) stores its failure code in the job's
      `meta["last_error"]`, where `Run` reads it, and then broadcasts
      `:attempt_failed`. `failure_code/1` derives the code from the exception
      Oban reports, never from its message.
    * A final attempt that raised, crashed, or hit the job timeout
      (`state: :discard`) records one failed extraction through
      `Worker.persist_and_emit_failure/4`, which broadcasts `:failed`. Its
      message is the described code, never the exception's text. `OCRJob`
      records its own final failures and completes, so only these reach
      Oban's discard. It is a no-op when the document is gone, a newer run
      already wrote its row, or Retry processing already started a new run.
      `DocumentProcessing.retry_document/2` holds the same document row lock,
      so a retry reads either the recorded failure or no failure at all.
    * A run `OCRJob` cancelled because it could not record its failure
      (`[:oban, :job, :stop]` with `{:cancel, {:failure_not_recorded, _}}`)
      broadcasts `:failed` without an extraction, so open pages show the
      document as stalled.

  `Oban.Lifeline` reports the jobs it moves out of `executing` after their node
  died (`[:oban, :plugin, :stop]`). A rescued OCR job is handled as a failed
  attempt and a discarded one as a final attempt, both with
  `"job_interrupted"`.

  Oban emits each event after it has written the job's new state, so a page
  that re-reads on the broadcast sees it. A handler runs in the job's process,
  in the task Oban starts to report a timeout or crash, or in the Lifeline
  process, so its database writes delay only that process.
  """

  import Ecto.Query

  require Logger

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.DocumentProcessing.Worker
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @handler_id "zaimu-tomo-ocr-attempt-outcomes"
  @events [[:oban, :job, :exception], [:oban, :job, :stop], [:oban, :plugin, :stop]]
  @worker inspect(OCRJob)
  @interrupted "job_interrupted"

  @doc """
  Attaches the handler to Oban's job and plugin events. Safe to call repeatedly.
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
    error -> Logger.warning("[OCR] Attempt outcome not handled: #{inspect(error.__struct__)}")
  end

  defp handle([:oban, :job, :exception], %{job: %Oban.Job{worker: @worker} = job} = meta) do
    code = failure_code(meta.reason)

    case meta.state do
      :failure -> retrying(job, code)
      :discard -> gave_up(job, code)
    end
  end

  defp handle(
         [:oban, :job, :stop],
         %{
           state: :cancelled,
           result: {:cancel, {:failure_not_recorded, _summary}},
           job: %Oban.Job{worker: @worker, args: %{"document_id" => id}}
         }
       ) do
    notify(:failed, id)
  end

  defp handle(
         [:oban, :plugin, :stop],
         %{plugin: Oban.Lifeline, rescued_jobs: rescued, discarded_jobs: discarded}
       ) do
    rescued
    |> ocr_jobs()
    |> Enum.filter(&(&1.state == "available"))
    |> Enum.each(&retrying(&1, @interrupted))

    Enum.each(ocr_jobs(discarded), &gave_up(&1, @interrupted))
  end

  defp handle(_event, _meta), do: :ok

  # Lifeline commits a rescue before it reports it, so the job can run again
  # first. Writing only while `attempted_at` is unchanged keeps a newer
  # attempt's reason.
  defp retrying(%Oban.Job{args: %{"document_id" => id}} = job, code) do
    {updated, _} =
      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id and j.attempted_at == ^job.attempted_at),
        set: [meta: Map.put(job.meta, "last_error", code)]
      )

    if updated == 1, do: notify(:attempt_failed, id)
  end

  defp gave_up(%Oban.Job{args: %{"document_id" => id} = args}, code) do
    case Repo.get(Document, id) do
      nil -> :ok
      document -> record_failure(document, code, args["supersedes_extraction_id"])
    end
  end

  defp record_failure(document, code, expected_extraction_id) do
    error = {:job_discarded, reason_text(code)}

    case Worker.persist_and_emit_failure(document, error, expected_extraction_id,
           unless_live_run: true
         ) do
      {:ok, _content} ->
        Logger.warning("[OCR] Processing failed for document #{document.id} (discarded): #{code}")

      {:error, {:persistence_failed, _errors}} ->
        notify(:failed, document.id)

      {:error, _already_processed_or_deleted} ->
        :ok
    end
  end

  defp reason_text(code) do
    {first, rest} = code |> ErrorClassification.describe() |> String.split_at(1)
    String.upcase(first) <> rest
  end

  defp ocr_jobs([]), do: []

  defp ocr_jobs(lifeline_jobs) do
    ids = Enum.map(lifeline_jobs, & &1.id)
    Repo.all(from j in Oban.Job, where: j.id in ^ids and j.worker == @worker)
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
