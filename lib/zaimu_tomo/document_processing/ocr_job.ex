defmodule ZaimuTomo.DocumentProcessing.OCRJob do
  @moduledoc """
  Durable OCR -> extraction -> verification run for one document.

  Args are a self-contained command resolved at enqueue time: `document_id`,
  `currency_hint` (the owner's base currency snapshot) and
  `supersedes_extraction_id` (the latest extraction id at enqueue time, or nil).
  The job never queries Accounts.

  A `{:cancel, reason}` return voids the job (deleted document, or already
  processed by an earlier attempt after a Lifeline rescue). A transient error on
  a non-final attempt returns `{:error, reason}` WITHOUT persisting, so Oban
  backs off and retries; a permanent error, or a transient error on the final
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
      document
      |> then(&Worker.run(%{document: &1, currency_hint: hint}))
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
  # was enqueued, an earlier attempt already finished its work.
  defp ensure_not_superseded(document, args) do
    expected = Map.get(args, "supersedes_extraction_id")

    case ExtractedContentContext.get_latest_by_document(document.id) do
      nil when is_nil(expected) -> :ok
      %{id: ^expected} -> :ok
      _newer -> {:cancel, :already_processed}
    end
  end

  defp handle_result({:ok, _content}, _document, _job), do: :ok

  defp handle_result({:error, reason}, document, job) do
    handle_failure(ErrorClassification.classify(reason), final_attempt?(job), document, reason)
  end

  # Transient and not the final attempt: retry without persisting anything.
  defp handle_failure(:transient, false, _document, reason), do: {:error, reason}

  # Permanent (any attempt) or transient on the final attempt: record one failure.
  defp handle_failure(_class, _final?, document, reason), do: record_failure(document, reason)

  defp record_failure(document, reason) do
    case Worker.persist_and_emit_failure(document, reason) do
      {:ok, _content} ->
        :ok

      {:error, {:persistence_failed, errors}} ->
        handle_persist_failure(document, errors)
    end
  end

  # A :document_id FK violation means the document was deleted between fetch and
  # persist, so the run is void. Any other persistence failure is logged and
  # treated as recorded so the job does not spin on an unrecordable failure.
  defp handle_persist_failure(document, errors) do
    if Keyword.has_key?(errors, :document_id) do
      {:cancel, :document_deleted}
    else
      Logger.error(
        "[OCR] Could not record failure for document #{document.id}: #{inspect(errors)}"
      )

      :ok
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
