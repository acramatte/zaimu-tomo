defmodule ZaimuTomo.Review do
  @moduledoc """
  Context for reviewing OCR/LLM processed invoice data.

  Handles approve / reject / amend decisions on extracted invoices.
  Each decision updates a single ReviewDecision row in place and appends
  an immutable entry to EventLog for audit purposes.
  """

  import Ecto.Query, warn: false
  require Logger

  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

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

  def approve_invoice(extracted_content_id, user_id, notes \\ nil) do
    with {:ok, decision} <- get_pending_decision(extracted_content_id, user_id),
         {:ok, updated} <-
           update_review_decision(decision, %{
             review_status: "approved",
             decision_type: "approved",
             review_notes: notes,
             review_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
           }) do
      write_event_log("invoice_approved", extracted_content_id, user_id, %{notes: notes})
      emit_review_completed_event(updated, "approved")
      {:ok, updated}
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

  def amend_invoice(extracted_content_id, user_id, amended_data, notes \\ nil) do
    with {:ok, decision} <- get_pending_decision(extracted_content_id, user_id),
         {:ok, updated} <-
           update_review_decision(decision, %{
             review_status: "amended",
             decision_type: "amended",
             status: "completed",
             decision_data: amended_data,
             review_notes: notes,
             review_completed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
           }) do
      write_event_log("invoice_amended", extracted_content_id, user_id, %{
        amended_data: amended_data,
        notes: notes
      })

      emit_review_completed_event(updated, "amended")
      {:ok, updated}
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

  defp write_event_log(event_type, invoice_id, user_id, metadata) do
    result =
      EventLog.changeset_for_create(%{
        event_type: event_type,
        invoice_id: to_string(invoice_id),
        user_id: user_id,
        metadata: metadata,
        status: "completed"
      })
      |> Repo.insert()

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write event log for #{event_type}: #{inspect(reason)}")
        :ok
    end
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
