defmodule ZaimuTomo.Review do
  @moduledoc """
  Context for reviewing OCR/LLM processed invoice data.

  Handles approve / reject / amend decisions on extracted invoices.
  Each decision updates a single ReviewDecision row in place and appends
  an immutable entry to EventLog for audit purposes.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document

  # ---------------------------------------------------------------------------
  # Initial decision creation (called by OCR worker)
  # ---------------------------------------------------------------------------

  def create_initial_decision(%ExtractedContent{} = content) do
    ReviewDecision.changeset_for_create(%{
      extracted_content_id: content.id,
      user_id: content.user_id,
      review_status: "pending",
      decision_type: "initial",
      original_data: content.extracted_data
    })
    |> Repo.insert()
  end

  def create_failed_decision(%ExtractedContent{} = content, error) do
    ReviewDecision.changeset_for_create(%{
      extracted_content_id: content.id,
      user_id: content.user_id,
      review_status: "failed",
      decision_type: "failed",
      review_notes: failure_review_note(error)
    })
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Human review actions
  # ---------------------------------------------------------------------------

  @doc """
  Approves a pending invoice and posts its journal entry in one transaction.

  Options:

    * `:confirm_file_reuse` — `true` when the reviewer explicitly confirmed
      that the source file is a legitimate reuse (for example, a reused
      QR-bill) of an already posted file. Honored only when the duplicate
      check's verdict is `:file_reuse`; see `post_review_transaction/6`.

  Returns `{:error, :duplicate_invoice}` when a duplicate blocks the posting
  and `{:error, :file_reuse_not_applicable}` when a reuse was confirmed but
  no confirmable file match exists.
  """
  def approve_invoice(extracted_content_id, user_id, notes \\ nil, opts \\ []) do
    with {:ok, decision} <- get_pending_decision(extracted_content_id, user_id) do
      post_review_transaction(
        decision,
        %{
          review_status: "approved",
          decision_type: "approved",
          review_notes: notes,
          review_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        "invoice_approved",
        %{notes: notes},
        "approved",
        opts
      )
    end
  end

  def reject_invoice(extracted_content_id, user_id, rejection_reason, notes \\ nil) do
    with {:ok, decision} <- get_pending_decision(extracted_content_id, user_id),
         {:ok, updated} <-
           update_review_decision(decision, %{
             review_status: "rejected",
             decision_type: "rejected",
             rejection_reason: rejection_reason,
             review_notes: notes,
             review_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
           }) do
      write_event_log("invoice_rejected", extracted_content_id, user_id, %{
        rejection_reason: rejection_reason,
        notes: notes
      })

      emit_review_completed_event(updated, "rejected")
      {:ok, updated}
    end
  end

  @doc """
  Amends a pending invoice and posts its journal entry in one transaction.

  Accepts the same options and errors as `approve_invoice/4`. The duplicate
  check runs on the amended facts, so correcting the date of a reused slip can
  turn a blocked exact-file match into a confirmable one.
  """
  def amend_invoice(extracted_content_id, user_id, amended_data, notes \\ nil, opts \\ []) do
    with {:ok, decision} <- get_pending_decision(extracted_content_id, user_id) do
      post_review_transaction(
        decision,
        %{
          review_status: "amended",
          decision_type: "amended",
          status: "completed",
          decision_data: amended_data,
          review_notes: notes,
          review_completed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        },
        "invoice_amended",
        %{amended_data: amended_data, notes: notes},
        "amended",
        opts
      )
    end
  end

  @doc """
  Records user feedback about extraction quality on the Langfuse trace
  associated with the given extracted content.

  `value` is `1` for correct, `0` for incorrect. Returns `:ok` when the score
  was recorded (or Langfuse is not configured, in which case it is a no-op).
  """
  def submit_extraction_feedback(extracted_content_id, user_id, value, comment \\ nil) do
    with {:ok, content} <- get_owned_extracted_content(extracted_content_id, user_id),
         true <- is_binary(content.trace_id) do
      Langfuse.create_user_score(content.trace_id, value, comment)
    else
      nil -> {:error, "Extracted content not found or not owned by user"}
      false -> {:error, "No Langfuse trace recorded for this extraction"}
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Runs `Accounting.duplicate_check/3` for a review decision against `data`
  (its effective data, or amended data not yet saved), using the source
  document's fingerprint loaded through the decision's own user scope.

  The fingerprint itself never leaves the server-side contexts.
  """
  @spec duplicate_check(ReviewDecision.t(), ExtractedData.t()) :: Accounting.duplicate_check()
  def duplicate_check(%ReviewDecision{} = decision, %ExtractedData{} = data) do
    Accounting.duplicate_check(decision.user_id, data, source_document_sha256(Repo, decision))
  end

  def list_review_decisions(user_id) do
    query =
      from rd in ReviewDecision,
        join: ec in ExtractedContent,
        on: ec.id == rd.extracted_content_id,
        where: ec.user_id == ^user_id,
        order_by: [desc: rd.review_status == "pending", desc: rd.inserted_at]

    Repo.all(query)
  end

  def get_review_decision(id, user_id) do
    query =
      from rd in ReviewDecision,
        join: ec in ExtractedContent,
        on: ec.id == rd.extracted_content_id,
        where: rd.id == ^id,
        where: ec.user_id == ^user_id,
        preload: [extracted_content: ec]

    case Repo.one(query) do
      nil -> {:error, "Review decision not found or not owned by user"}
      review_decision -> {:ok, review_decision}
    end
  end

  @doc """
  Returns the number of the user's reviews awaiting a decision.
  """
  def pending_review_count(%Scope{} = scope) do
    from(rd in ReviewDecision,
      where: rd.user_id == ^scope.user.id,
      where: rd.review_status == "pending",
      select: count(rd.id)
    )
    |> Repo.one()
  end

  def get_review_status_counts(user_id) do
    ReviewDecision
    |> join(:left, [rd], ec in ExtractedContent, on: ec.id == rd.extracted_content_id)
    |> where(
      [rd, ec],
      ec.user_id == ^user_id and
        rd.review_status in ["pending", "approved", "rejected", "amended"]
    )
    |> group_by([rd, _], rd.review_status)
    |> select([rd, _], %{status: rd.review_status, count: count(rd.id)})
    |> Repo.all()
    |> Enum.into(%{}, fn %{status: status, count: count} -> {String.to_atom(status), count} end)
  end

  def update_review_decision(%ReviewDecision{} = review_decision, attrs) do
    review_decision
    |> ReviewDecision.changeset_for_update(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp failure_review_note({type, _reason}) when is_atom(type),
    do: "Automatically marked as failed: #{type}"

  defp failure_review_note(type) when is_atom(type),
    do: "Automatically marked as failed: #{type}"

  defp failure_review_note(_error), do: "Automatically marked as failed: unknown error"

  defp get_pending_decision(extracted_content_id, user_id) do
    query =
      from rd in ReviewDecision,
        join: ec in ExtractedContent,
        on: ec.id == rd.extracted_content_id,
        where: rd.extracted_content_id == ^extracted_content_id,
        where: ec.user_id == ^user_id,
        where: rd.review_status == "pending"

    case Repo.one(query) do
      nil -> {:error, "No pending review found for this invoice"}
      decision -> {:ok, decision}
    end
  end

  defp get_owned_extracted_content(extracted_content_id, user_id) do
    case Repo.get_by(ExtractedContent, id: extracted_content_id, user_id: user_id) do
      nil -> nil
      content -> {:ok, content}
    end
  end

  # Marks a pending review as approved or amended and posts its journal entry in
  # ONE transaction.
  #
  # The journal entry is created from the decision's effective data (amended data
  # when present, original otherwise) in the same transaction that updates the
  # review, and carries the source document's fingerprint. A duplicate invoice —
  # enforced by the unique (user, issuer, invoice number) index or the unique
  # (user, source file digest) index over unconfirmed postings — rolls the whole
  # transition back and the review stays pending. Returns
  # `{:error, :duplicate_invoice}` in that case, `{:error, changeset}` for other
  # failures.
  #
  # With `confirm_file_reuse: true`, the duplicate check is re-run inside the
  # transaction on the effective data. Only a `:file_reuse` verdict marks the
  # entry `source_file_reuse_confirmed` and records the confirmation with the
  # matched entry IDs in the event log; a blocked verdict is refused as a
  # duplicate, and any other verdict as `:file_reuse_not_applicable`, so a
  # confirmation is never inferred or applied to the wrong match.
  defp post_review_transaction(
         decision,
         changeset_attrs,
         event_type,
         event_metadata,
         status,
         opts
       ) do
    confirm_file_reuse? = Keyword.get(opts, :confirm_file_reuse, false) == true

    Multi.new()
    |> Multi.run(:source_document_sha256, fn repo, _changes ->
      {:ok, source_document_sha256(repo, decision)}
    end)
    |> Multi.update(
      :review_decision,
      ReviewDecision.changeset_for_update(decision, changeset_attrs)
    )
    |> Multi.run(:file_reuse, fn _repo, changes ->
      file_reuse_confirmation(confirm_file_reuse?, changes)
    end)
    |> Multi.merge(fn %{review_decision: updated} = changes ->
      Accounting.create_multi_from_decision(updated, %{},
        source_document_sha256: changes.source_document_sha256,
        source_file_reuse_confirmed: changes.file_reuse != nil
      )
    end)
    |> Multi.run(:event_log, fn repo, %{review_decision: updated} ->
      insert_event_log(
        repo,
        event_type,
        updated.extracted_content_id,
        updated.user_id,
        event_metadata
      )
    end)
    |> Multi.run(:file_reuse_event_log, fn repo, changes ->
      insert_file_reuse_event_log(repo, changes)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{review_decision: updated}} ->
        emit_review_completed_event(updated, status)
        {:ok, updated}

      {:error, :file_reuse, reason, _changes} ->
        {:error, reason}

      {:error, :journal_entry, %Ecto.Changeset{} = changeset, _changes} ->
        if Accounting.duplicate_error?(changeset) do
          {:error, :duplicate_invoice}
        else
          {:error, changeset}
        end

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp file_reuse_confirmation(false, _changes), do: {:ok, nil}

  defp file_reuse_confirmation(true, %{
         review_decision: updated,
         source_document_sha256: source_sha256
       }) do
    check =
      Accounting.duplicate_check(
        updated.user_id,
        ReviewDecision.effective_data(updated),
        source_sha256
      )

    case check.verdict do
      :file_reuse ->
        {:ok, %{matched_journal_entry_ids: Enum.map(check.candidates, & &1.entry.id)}}

      verdict when verdict in [:invoice_number, :same_file_blocked] ->
        {:error, :duplicate_invoice}

      _no_file_match ->
        {:error, :file_reuse_not_applicable}
    end
  end

  defp insert_file_reuse_event_log(_repo, %{file_reuse: nil}), do: {:ok, nil}

  defp insert_file_reuse_event_log(repo, %{
         file_reuse: %{matched_journal_entry_ids: [matched_id | _] = matched_ids},
         journal_entry: entry,
         review_decision: updated
       }) do
    insert_event_log(
      repo,
      "source_file_reuse_confirmed",
      updated.extracted_content_id,
      updated.user_id,
      %{
        journal_entry_id: entry.id,
        matched_journal_entry_id: matched_id,
        matched_journal_entry_ids: matched_ids
      }
    )
  end

  # Loads the decision's source document fingerprint, scoped to the decision's
  # user through both the extraction and the document.
  defp source_document_sha256(repo, %ReviewDecision{} = decision) do
    from(ec in ExtractedContent,
      join: d in Document,
      on: d.id == ec.document_id,
      where: ec.id == ^decision.extracted_content_id,
      where: ec.user_id == ^decision.user_id and d.user_id == ^decision.user_id,
      select: d.content_sha256
    )
    |> repo.one()
  end

  # Best-effort audit write for transitions that do not post a journal entry.
  defp write_event_log(event_type, invoice_id, user_id, metadata) do
    case insert_event_log(Repo, event_type, invoice_id, user_id, metadata) do
      {:ok, _event_log} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write event log for #{event_type}: #{inspect(reason)}")
        :ok
    end
  end

  # Inside the posting transaction the audit entry is required: an error
  # rolls back the review update and the journal entry with it.
  defp insert_event_log(repo, event_type, invoice_id, user_id, metadata) do
    %{
      event_type: event_type,
      invoice_id: to_string(invoice_id),
      user_id: user_id,
      metadata: metadata,
      status: "completed"
    }
    |> EventLog.changeset_for_create()
    |> repo.insert()
  end

  defp emit_review_completed_event(%ReviewDecision{} = decision, status) do
    Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "invoice_review:completed", %{
      invoice_id: decision.extracted_content_id,
      status: status,
      user_id: decision.user_id,
      decision_data: decision.decision_data,
      timestamp: DateTime.utc_now()
    })
  end
end
