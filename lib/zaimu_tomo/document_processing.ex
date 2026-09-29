defmodule ZaimuTomo.DocumentProcessing do
  @moduledoc """
  The DocumentProcessing context.

  Builds durable OCR job commands that Oban dispatches. The enqueue is atomic
  with the document insert (see `ZaimuTomo.Documents.create_document/2`), so an
  upload can never exist without its processing job.

  Also owns the processing state of a document and the scope-checked retry
  entry point for failed or stuck runs.
  """

  import Ecto.Query

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @ocr_job_worker "ZaimuTomo.DocumentProcessing.OCRJob"
  @live_job_states ~w(available scheduled executing retryable)

  @typedoc """
  Processing state of a document:

    * `:processing` — a live OCR job exists (queued, scheduled or running)
    * `:stuck` — no extraction and no live job (the run was lost)
    * `:failed` — the latest extraction failed
    * `:extracted` — the latest extraction succeeded
  """
  @type processing_state :: :processing | :stuck | :failed | :extracted

  @doc """
  Builds the OCR job changeset for a document.

  The command is self-contained and resolved at enqueue time: the document id,
  a queue-time snapshot of the owner's base currency (`currency_hint`), and the
  latest extraction id to supersede (or `nil` when there is none). The worker
  pattern-matches this command and never queries Accounts.
  """
  def ocr_job(%Document{} = document, currency_hint, supersedes_extraction_id) do
    OCRJob.new(%{
      document_id: document.id,
      currency_hint: currency_hint,
      supersedes_extraction_id: supersedes_extraction_id
    })
  end

  @doc """
  Returns the processing state of a document.
  """
  @spec processing_state(Document.t()) :: processing_state()
  def processing_state(%Document{} = document) do
    latest = ExtractedContentContext.get_latest_by_document(document.id)
    classify_state(live_job?(document.id), latest)
  end

  defp classify_state(true, _latest), do: :processing
  defp classify_state(false, nil), do: :stuck
  defp classify_state(false, %{status: "failed"}), do: :failed
  defp classify_state(false, %{status: "success"}), do: :extracted

  @doc """
  Retries processing for a document whose latest run failed or stalled.

  Scope-checked: a document owned by another user returns `{:error, :not_found}`.
  Only `:failed` and `:stuck` are retryable; any other state returns
  `{:error, {:not_retryable, state}}`. The enqueue carries the latest extraction
  id as `supersedes_extraction_id` (nil when stuck), and failed rows are kept as
  history — the new run appends a row. An Oban uniqueness conflict counts as
  success: at most one live job can exist per document.
  """
  @spec retry_document(Scope.t(), Document.t()) ::
          {:ok, Oban.Job.t()} | {:error, :not_found | {:not_retryable, processing_state()}}
  def retry_document(%Scope{user: %{id: user_id}} = scope, %Document{user_id: user_id} = document) do
    latest = ExtractedContentContext.get_latest_by_document(document.id)

    case classify_state(live_job?(document.id), latest) do
      state when state in [:failed, :stuck] ->
        document
        |> ocr_job(scope.user.base_currency, latest && latest.id)
        |> Oban.insert()

      state ->
        {:error, {:not_retryable, state}}
    end
  end

  def retry_document(%Scope{}, %Document{}), do: {:error, :not_found}

  @doc """
  Returns true when a live OCR job exists for the document.
  """
  @spec live_job?(pos_integer()) :: boolean()
  def live_job?(document_id) do
    live_jobs()
    |> where([j], fragment("(?->>'document_id')::bigint = ?", j.args, ^document_id))
    |> limit(1)
    |> Repo.one()
    |> case do
      %Oban.Job{} -> true
      nil -> false
    end
  end

  @doc """
  Base query over live OCR jobs (worker + states that still count as in-flight).
  """
  @spec live_jobs() :: Ecto.Query.t()
  def live_jobs do
    from j in Oban.Job,
      where: j.worker == @ocr_job_worker,
      where: j.state in @live_job_states
  end
end
