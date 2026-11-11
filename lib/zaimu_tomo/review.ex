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
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Review.ReviewDecision

  @doc """
  Where an invoice stands, from its latest extraction: `"processing"`,
  `"failed"`, `"review"`, `"posted"` or `"rejected"`.

  The rule for a completed extraction; surfaces call `document_status/2`, which
  puts the processing state first. An invoice approved before booking was part
  of posting is `"review"` until its entry is booked, so the decision must be
  loaded with its `journal_entry`.
  """
  @spec invoice_status(ExtractedContent.t() | nil) :: String.t()
  def invoice_status(nil), do: "processing"
  def invoice_status(%{status: "failed"}), do: "failed"

  def invoice_status(%{review_decision: %{journal_entry: %Ecto.Association.NotLoaded{}}}) do
    raise ArgumentError, "invoice_status/1 needs the review decision's journal_entry preloaded"
  end

  def invoice_status(%{review_decision: %{journal_entry: %{status: "uncategorized"}}}),
    do: "review"

  def invoice_status(%{review_decision: %{review_status: s}}) when s in ["approved", "amended"],
    do: "posted"

  def invoice_status(%{review_decision: %{review_status: "rejected"}}), do: "rejected"
  def invoice_status(_content), do: "review"

  @doc """
  A document's status on the document list, the activity feed, and the invoice
  page: its processing state from `DocumentProcessing.processing_states/1`
  first (`"processing"`, `"stalled"`, `"failed"`), then `invoice_status/1` of
  its latest extraction once a run has completed.
  """
  @spec document_status(DocumentProcessing.processing_state(), ExtractedContent.t() | nil) ::
          String.t()
  def document_status(:processing, _content), do: "processing"
  def document_status(:stuck, _content), do: "stalled"
  def document_status(:failed, _content), do: "failed"
  def document_status(:extracted, content), do: invoice_status(content)

  @doc """
  True for a `document_status/2` the user still has to act on: an invoice to
  check or book, or an extraction to retry or wait for. This is the document
  list's Needs action tab.
  """
  @spec needs_action?(String.t()) :: boolean()
  def needs_action?(status), do: status in ["review", "failed", "stalled", "processing"]

  @doc "Counts the scope's documents in the document list's Needs action tab."
  @spec needs_action_count(Scope.t()) :: non_neg_integer()
  def needs_action_count(%Scope{} = scope) do
    documents = Documents.list_documents(scope)
    states = DocumentProcessing.processing_states(Enum.map(documents, & &1.id))

    Enum.count(documents, fn document ->
      states[document.id]
      |> document_status(List.first(document.extracted_content))
      |> needs_action?()
    end)
  end

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

    * `:confirm` — the duplicate verdict the reviewer explicitly confirmed:
      `:possible` ("post anyway") or `:file_reuse` (the source file is a
      legitimate reuse, for example a reused QR-bill). It applies only when
      the duplicate check inside the transaction returns that same verdict;
      see `posting_decision/2`.
    * `:booking` — `%{category, need_or_want, notes}`; when given, the journal
      entry is created already categorized and posted instead of
      `uncategorized`, in the same transaction.
    * `:tax_claim_attrs` — attributes for the entry's tax deduction claim,
      such as `%{"status" => "candidate"}`; defaults to undecided.

  Returns `{:error, {:confirmation_required, verdict}}` when the posting needs
  the reviewer's confirmation of `verdict` first, `{:error, :duplicate_invoice}`
  when a duplicate blocks the posting, and
  `{:error, :confirmation_not_applicable}` when the confirmation given is not
  for the current verdict.
  """
  def approve_invoice(extracted_content_id, user_id, notes \\ nil, opts \\ []) do
    post_review_transaction(
      extracted_content_id,
      user_id,
      "approved",
      %{review_notes: notes},
      %{notes: notes},
      opts
    )
  end

  @doc """
  Rejects a pending invoice with a reason, and records it in the event log, in
  one transaction. Nothing is posted.
  """
  def reject_invoice(extracted_content_id, user_id, rejection_reason, notes \\ nil) do
    Multi.new()
    |> decide(extracted_content_id, user_id, "rejected", %{
      rejection_reason: rejection_reason,
      review_notes: notes
    })
    |> Multi.run(:event_log, fn repo, _changes ->
      insert_event_log(repo, "invoice_rejected", extracted_content_id, user_id, %{
        rejection_reason: rejection_reason,
        notes: notes
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{review_decision: updated}} ->
        emit_review_completed_event(updated, "rejected")
        {:ok, updated}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Amends a pending invoice and posts its journal entry in one transaction.

  Accepts the same options and errors as `approve_invoice/4`. The duplicate
  check runs on the amended facts, so correcting the date of a reused slip can
  turn a blocked exact-file match into a confirmable one.
  """
  def amend_invoice(extracted_content_id, user_id, amended_data, notes \\ nil, opts \\ []) do
    post_review_transaction(
      extracted_content_id,
      user_id,
      "amended",
      %{decision_data: amended_data, review_notes: notes},
      %{amended_data: amended_data, notes: notes},
      opts
    )
  end

  @doc """
  Scores the extraction of an invoice that was just posted, in the background.

  Without an explicit `override` (`0` or `1`), the score is `1` when the
  invoice was posted as extracted and `0` when fields were corrected. The
  comment lists the corrected fields with their extracted and posted values;
  the reviewer's own comment is never sent. A no-op without a Langfuse trace.
  """
  @spec score_posted_extraction(ExtractedContent.t(), [{atom(), term(), term()}], 0 | 1 | nil) ::
          :ok
  def score_posted_extraction(content, changes, override \\ nil)

  def score_posted_extraction(%ExtractedContent{trace_id: trace_id}, changes, override)
      when is_binary(trace_id) do
    value = override || if(changes == [], do: 1, else: 0)

    comment =
      if changes != [] do
        "Corrected before posting: " <>
          Enum.map_join(changes, "; ", fn {field, from, to} ->
            "#{field} #{inspect(from)} -> #{inspect(to)}"
          end)
      end

    send_extraction_score(trace_id, value, comment)
  end

  def score_posted_extraction(_content, _changes, _override), do: :ok

  @doc """
  Records the reviewer's explicit 👍/👎 (`1` or `0`) when rejecting an invoice,
  in the background. A rejection alone says nothing about the extraction (a
  correctly read duplicate is rejected too), so without a choice nothing is sent.
  The rejection reason is never sent.
  """
  @spec score_rejected_extraction(ExtractedContent.t(), 0 | 1 | nil) :: :ok
  def score_rejected_extraction(%ExtractedContent{trace_id: trace_id}, value)
      when is_binary(trace_id) and value in [0, 1] do
    send_extraction_score(trace_id, value, "Rejected before posting")
  end

  def score_rejected_extraction(_content, _value), do: :ok

  defp send_extraction_score(trace_id, value, comment) do
    Task.start(fn ->
      with {:error, reason} <- Langfuse.create_user_score(trace_id, value, comment) do
        Logger.warning("Failed to record extraction score: #{inspect(reason)}")
      end
    end)

    :ok
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

  @typedoc "The duplicate verdict a reviewer explicitly confirmed, if any."
  @type confirmation :: nil | :possible | :file_reuse

  @doc """
  The duplicate gate: what a posting does for a duplicate verdict and the
  reviewer's confirmation.

    * `:post` — nothing matches, or the reviewer confirmed this exact verdict.
    * `{:confirm, verdict}` — a soft match or a reused file; ask the reviewer.
    * `{:refuse, :duplicate_invoice}` — a hard block; no confirmation lifts it.
    * `{:refuse, :confirmation_not_applicable}` — the confirmation is for
      another verdict (the matches changed, or the data was edited), so it is
      never applied to a match the reviewer did not see.

  The posting transaction evaluates it on the data being posted; the invoice
  page uses it only to know which confirmation to offer.
  """
  @spec posting_decision(Accounting.verdict(), confirmation()) ::
          :post
          | {:confirm, :possible | :file_reuse}
          | {:refuse, :duplicate_invoice | :confirmation_not_applicable}
  def posting_decision(:none, nil), do: :post

  def posting_decision(verdict, nil) when verdict in [:possible, :file_reuse],
    do: {:confirm, verdict}

  def posting_decision(verdict, verdict) when verdict in [:possible, :file_reuse], do: :post

  def posting_decision(verdict, _confirmation)
      when verdict in [:invoice_number, :same_file_blocked],
      do: {:refuse, :duplicate_invoice}

  def posting_decision(_verdict, _other_confirmation),
    do: {:refuse, :confirmation_not_applicable}

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp failure_review_note({type, _reason}) when is_atom(type),
    do: "Automatically marked as failed: #{type}"

  defp failure_review_note(type) when is_atom(type),
    do: "Automatically marked as failed: #{type}"

  defp failure_review_note(_error), do: "Automatically marked as failed: unknown error"

  # The one place a review is decided. Adds a `:review_decision` step that
  # locks the user's pending review row and applies the transition, so of two
  # concurrent decisions on one review the second waits, then finds it no
  # longer pending and fails with the message below.
  defp decide(multi, extracted_content_id, user_id, to, attrs) do
    Multi.run(multi, :review_decision, fn repo, _changes ->
      query =
        from rd in ReviewDecision,
          join: ec in ExtractedContent,
          on: ec.id == rd.extracted_content_id,
          where: rd.extracted_content_id == ^extracted_content_id,
          where: ec.user_id == ^user_id,
          where: rd.review_status == "pending",
          lock: fragment("FOR UPDATE OF ?", rd)

      case repo.one(query) do
        nil -> {:error, "No pending review found for this invoice"}
        decision -> decision |> ReviewDecision.decide_changeset(to, attrs) |> repo.update()
      end
    end)
  end

  # Decides a pending review as approved or amended (`to`) and posts its journal
  # entry in ONE transaction.
  #
  # The journal entry is created from the decision's effective data (amended data
  # when present, original otherwise) in the same transaction that updates the
  # review, and carries the source document's fingerprint.
  #
  # The duplicate gate always runs inside the transaction, on the effective
  # data, and `posting_decision/2` decides: anything but `:post` rolls the
  # whole transition back and the review stays pending. A user's postings are
  # serialized by an advisory lock, so the check sees every earlier posting.
  # Every confirmation is recorded in the event log with the matched entry IDs
  # (`@confirmation_events`); only a confirmed `:file_reuse` also marks the
  # entry `source_file_reuse_confirmed`.
  #
  # The unique (user, issuer, invoice number) index and the unique (user, source
  # file digest) index over unconfirmed postings remain as a backstop for any
  # writer that skips the gate; a violation is `{:error, :duplicate_invoice}`.
  # Other failures return `{:error, changeset}`.
  defp post_review_transaction(extracted_content_id, user_id, to, attrs, event_metadata, opts) do
    confirmation = Keyword.get(opts, :confirm)
    booking = Keyword.get(opts, :booking)
    tax_claim_attrs = Keyword.get(opts, :tax_claim_attrs, %{})

    event_metadata =
      if booking,
        do: Map.merge(event_metadata, %{booking: booking, tax_claim: tax_claim_attrs}),
        else: event_metadata

    Multi.new()
    |> Multi.run(:posting_lock, fn repo, _changes ->
      repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", ["journal_posting:#{user_id}"])
    end)
    |> decide(extracted_content_id, user_id, to, attrs)
    |> Multi.run(:source_document_sha256, fn repo, %{review_decision: updated} ->
      {:ok, source_document_sha256(repo, updated)}
    end)
    |> Multi.run(:duplicate_gate, fn _repo, changes ->
      duplicate_gate(confirmation, changes)
    end)
    |> Multi.merge(fn %{review_decision: updated} = changes ->
      Accounting.create_multi_from_decision(updated, tax_claim_attrs,
        source_document_sha256: changes.source_document_sha256,
        source_file_reuse_confirmed: changes.duplicate_gate.confirmed == :file_reuse,
        booking: booking
      )
    end)
    |> Multi.run(:event_log, fn repo, %{review_decision: updated} ->
      insert_event_log(
        repo,
        "invoice_#{to}",
        updated.extracted_content_id,
        updated.user_id,
        event_metadata
      )
    end)
    |> Multi.run(:confirmation_event_log, fn repo, changes ->
      insert_confirmation_event_log(repo, changes)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{review_decision: updated}} ->
        emit_review_completed_event(updated, to)
        {:ok, updated}

      {:error, operation, reason, _changes}
      when operation in [:review_decision, :duplicate_gate] ->
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

  defp duplicate_gate(confirmation, %{
         review_decision: updated,
         source_document_sha256: source_sha256
       }) do
    check =
      Accounting.duplicate_check(
        updated.user_id,
        ReviewDecision.effective_data(updated),
        source_sha256
      )

    case posting_decision(check.verdict, confirmation) do
      :post ->
        {:ok,
         %{
           confirmed: confirmation,
           matched_journal_entry_ids: Enum.map(check.candidates, & &1.entry.id)
         }}

      {:confirm, verdict} ->
        {:error, {:confirmation_required, verdict}}

      {:refuse, reason} ->
        {:error, reason}
    end
  end

  # The audit event for each confirmation a reviewer can give at the gate.
  @confirmation_events %{
    possible: "possible_duplicate_confirmed",
    file_reuse: "source_file_reuse_confirmed"
  }

  defp insert_confirmation_event_log(repo, %{
         duplicate_gate: %{
           confirmed: confirmation,
           matched_journal_entry_ids: [matched_id | _] = matched_ids
         },
         journal_entry: entry,
         review_decision: updated
       })
       when is_map_key(@confirmation_events, confirmation) do
    insert_event_log(
      repo,
      @confirmation_events[confirmation],
      updated.extracted_content_id,
      updated.user_id,
      %{
        journal_entry_id: entry.id,
        matched_journal_entry_id: matched_id,
        matched_journal_entry_ids: matched_ids
      }
    )
  end

  defp insert_confirmation_event_log(_repo, _changes), do: {:ok, nil}

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

  # Inside a review transaction the audit entry is required: an error rolls
  # back the decision, and the journal entry when one was posted, with it.
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
