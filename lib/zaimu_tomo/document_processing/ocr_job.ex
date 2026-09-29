defmodule ZaimuTomo.DocumentProcessing.OCRJob do
  @moduledoc """
  Durable OCR -> extraction -> verification run for one document.

  Args are a self-contained command resolved at enqueue time: `document_id`,
  `currency_hint` (the owner's base currency snapshot) and
  `supersedes_extraction_id` (the latest extraction id at enqueue time, or nil).
  The job never queries Accounts.

  A `{:cancel, reason}` return voids the job: deleted document, already
  processed by an earlier attempt after a Lifeline rescue, or a failure whose
  failed row could not be recorded. A transient error on a non-final attempt
  returns `{:error, ErrorClassification.summarize(reason)}` WITHOUT persisting,
  so Oban backs off and retries and no raw provider payload reaches
  `oban_jobs.errors`; a permanent error, or a transient error on the final
  attempt, persists exactly one failed row and completes.
  """
  use Oban.Worker,
    queue: :documents,
    max_attempts: 5,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: :infinity
    ]

  require Logger

  alias ZaimuTomo.DocumentProcessing.{ErrorClassification, ExtractedContentContext, Worker}
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => id, "currency_hint" => hint} = args} = job) do
    with {:ok, document} <- fetch_document(id),
         :ok <- ensure_not_superseded(document, args) do
      %{
        document: document,
        currency_hint: hint,
        supersedes_extraction_id: Map.get(args, "supersedes_extraction_id")
      }
      |> Worker.run()
      |> handle_result(document, job)
    end
  end

  defp fetch_document(id) do
    case Repo.get(Document, id) do
      %Document{} = document -> {:ok, document}
      nil -> {:cancel, :document_deleted}
    end
  end

  # Idempotency after a Lifeline rescue: if a row was appended since this job
  # was enqueued, an earlier attempt already finished its work. Cheap early
  # exit only — the authoritative re-check runs under the document-row lock
  # inside the persist transaction (see Worker.run/1).
  defp ensure_not_superseded(document, args) do
    expected = Map.get(args, "supersedes_extraction_id")

    case ExtractedContentContext.get_latest_by_document(document.id) do
      nil when is_nil(expected) -> :ok
      %{id: ^expected} -> :ok
      _newer -> {:cancel, :already_processed}
    end
  end

  defp handle_result({:ok, _content}, _document, _job), do: :ok

  defp handle_result({:error, :already_processed}, _document, _job),
    do: {:cancel, :already_processed}

  defp handle_result({:error, :document_deleted}, _document, _job),
    do: {:cancel, :document_deleted}

  defp handle_result({:error, reason}, document, job) do
    handle_failure(
      ErrorClassification.classify(reason),
      final_attempt?(job),
      document,
      reason,
      Map.get(job.args, "supersedes_extraction_id")
    )
  end

  # Transient and not the final attempt: retry without persisting anything.
  # Oban keeps only a bounded, body-free summary of the reason.
  defp handle_failure(:transient, false, _document, reason, _expected_extraction_id) do
    {:error, ErrorClassification.summarize(reason)}
  end

  # Permanent (any attempt) or transient on the final attempt: record one failure.
  defp handle_failure(_class, _final?, document, reason, expected_extraction_id) do
    record_failure(document, reason, expected_extraction_id)
  end

  defp record_failure(document, reason, expected_extraction_id) do
    case Worker.persist_and_emit_failure(document, reason, expected_extraction_id) do
      {:ok, _content} -> :ok
      {:error, :already_processed} -> {:cancel, :already_processed}
      {:error, :document_deleted} -> {:cancel, :document_deleted}
      {:error, {:persistence_failed, errors}} -> handle_persist_failure(document, errors)
    end
  end

  # The failed row could not be written and the run is not superseded: void the
  # job with an actionable audit trail instead of completing silently, so stuck
  # detection can surface the document (no row, no live job). The reason kept
  # in oban_jobs.errors is a short summary of the changeset error keys, never
  # provider payloads.
  defp handle_persist_failure(document, errors) do
    summary = changeset_error_summary(errors)

    Logger.error("[OCR] Could not record failure for document #{document.id}: #{summary}")

    {:cancel, {:failure_not_recorded, summary}}
  end

  defp changeset_error_summary(errors) do
    errors |> Keyword.keys() |> Enum.sort() |> Enum.join(",")
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
