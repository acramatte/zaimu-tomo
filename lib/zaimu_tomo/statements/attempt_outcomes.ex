defmodule ZaimuTomo.Statements.AttemptOutcomes do
  @moduledoc """
  Records what happened to a discarded statement extraction attempt once Oban
  has settled it, and tells the statement owner's open pages.

    * A final attempt that raised, crashed, or hit the job timeout
      (`[:oban, :job, :exception]` with `state: :discard`) delegates to
      `ExtractJob.record_discarded/2` with a code from
      `DocumentProcessing.AttemptOutcomes.failure_code/1` (`"job_timeout"` or
      `"unclassified"`, never the exception's message).
    * `Oban.Lifeline` reports jobs it moves out of `executing` after their node
      died (`[:oban, :plugin, :stop]`). A discarded `ExtractJob` delegates to
      `ExtractJob.record_discarded/2` with `"job_interrupted"`.

  Oban emits each event after committing the job's new state, so a page that
  re-reads on the broadcast sees it. All writes to statement extraction facts
  stay inside `ExtractJob`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias ZaimuTomo.DocumentProcessing.AttemptOutcomes, as: OCRAttemptOutcomes
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements.ExtractJob

  @handler_id "zaimu-tomo-statement-attempt-outcomes"
  @events [[:oban, :job, :exception], [:oban, :plugin, :stop]]
  @worker inspect(ExtractJob)
  @interrupted "job_interrupted"

  @doc """
  Attaches the handler to Oban's job and plugin events. Safe to call repeatedly.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(event, _measurements, meta, _config) do
    handle(event, meta)
  rescue
    error ->
      Logger.warning("[Statements] Attempt outcome not handled: #{inspect(error.__struct__)}")
  end

  defp handle(
         [:oban, :job, :exception],
         %{
           state: :discard,
           job: %Oban.Job{worker: @worker, args: %{"statement_id" => id}},
           reason: reason
         }
       ) do
    code = OCRAttemptOutcomes.failure_code(reason)
    ExtractJob.record_discarded(id, code)
  end

  defp handle([:oban, :plugin, :stop], %{plugin: Oban.Lifeline, discarded_jobs: discarded}) do
    discarded
    |> extract_jobs()
    |> Enum.each(fn %Oban.Job{args: %{"statement_id" => id}} ->
      ExtractJob.record_discarded(id, @interrupted)
    end)
  end

  defp handle(_event, _meta), do: :ok

  defp extract_jobs([]), do: []

  defp extract_jobs(lifeline_jobs) do
    ids = Enum.map(lifeline_jobs, & &1.id)
    Repo.all(from j in Oban.Job, where: j.id in ^ids and j.worker == @worker)
  end
end
