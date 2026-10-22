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
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @ocr_job_worker "ZaimuTomo.DocumentProcessing.OCRJob"
  @live_job_states ~w(available scheduled executing retryable)
  @event_kinds [:success, :failed, :retried]

  @typedoc """
  Processing state of a document:

    * `:processing` — a live OCR job exists (queued, scheduled or running)
    * `:stuck` — no extraction and no live job (the run was lost)
    * `:failed` — the latest extraction failed
    * `:extracted` — the latest extraction succeeded
  """
  @type processing_state :: :processing | :stuck | :failed | :extracted

  @doc """
  Subscribes the caller to the scope owner's processing events.

  Messages are the maps broadcast by `broadcast_event/3`: a run finished
  (`:success` / `:failed`) or a retry was enqueued (`:retried`). Topics are per
  owner, so a subscriber never receives another user's extracted data.
  """
  @spec subscribe_events(Scope.t()) :: :ok | {:error, term()}
  def subscribe_events(%Scope{user: %{id: user_id}}) do
    Enum.find_value(@event_kinds, :ok, fn kind ->
      case Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, event_topic(user_id, kind)) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @doc false
  @spec broadcast_event(:success | :failed | :retried, integer(), map()) ::
          :ok | {:error, term()}
  def broadcast_event(kind, user_id, payload) when kind in @event_kinds do
    Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, event_topic(user_id, kind), payload)
  end

  defp event_topic(user_id, kind), do: "user:#{user_id}:document_processing:#{kind}"

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

  @doc """
  Returns the processing state of many documents at once.

  Same semantics as `processing_state/1`, but resolved with two queries
  (live jobs and latest extraction per document) regardless of how many ids are
  given. Use it wherever a list of documents needs their current state.
  """
  @spec processing_states([pos_integer()]) :: %{pos_integer() => processing_state()}
  def processing_states([]), do: %{}

  def processing_states(document_ids) when is_list(document_ids) do
    live_ids =
      live_jobs()
      |> where(
        [j],
        fragment("?->>'document_id'", j.args) in ^Enum.map(document_ids, &to_string/1)
      )
      |> select([j], fragment("?->>'document_id'", j.args))
      |> Repo.all()
      |> MapSet.new()

    latest_statuses =
      ExtractedContent
      |> where([ec], ec.document_id in ^document_ids)
      |> distinct([ec], ec.document_id)
      |> order_by([ec], asc: ec.document_id, desc: ec.inserted_at, desc: ec.id)
      |> select([ec], {ec.document_id, ec.status})
      |> Repo.all()
      |> Map.new()

    Map.new(document_ids, fn id ->
      latest = latest_statuses[id] && %{status: latest_statuses[id]}
      {id, classify_state(MapSet.member?(live_ids, to_string(id)), latest)}
    end)
  end

  defp classify_state(true, _latest), do: :processing
  defp classify_state(false, nil), do: :stuck
  defp classify_state(false, %{status: "failed"}), do: :failed
  defp classify_state(false, %{status: "success"}), do: :extracted

  @doc """
  Retries processing for a document whose latest run failed or stalled.

  The document must be a persisted struct obtained through a scoped getter
  (e.g. `ZaimuTomo.Documents.get_document!/2`), matching the trust model of
  `ZaimuTomo.Documents.update_document/3`.
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
        with {:ok, job} <-
               document
               |> ocr_job(scope.user.base_currency, latest && latest.id)
               |> Oban.insert() do
          # Lets open Index / hero views pick up the new live run without a reload.
          broadcast_event(:retried, user_id, %{document_id: document.id, user_id: user_id})
          {:ok, job}
        end

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
    # Same safe text comparison as Recovery.list_stuck/0: no ::bigint cast on
    # job args, so a malformed job (missing or non-numeric document_id) is
    # simply not a match and never raises.
    live_jobs()
    |> where([j], fragment("?->>'document_id' = ?", j.args, ^to_string(document_id)))
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
