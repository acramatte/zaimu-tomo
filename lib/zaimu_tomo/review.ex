defmodule ZaimuTomo.Review do
  @moduledoc """
  Review module for OCR/LLM processed invoice data.

  This module provides the main context for reviewing invoices that have been
  processed by the OCR/LLM pipeline. It handles the business logic for:
  - Listing invoices needing review
  - Approving, rejecting, or amending invoices
  - Consuming document processing events
  - Emitting review completion events
  """

  import Ecto.Query, warn: false
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

  @doc """
  Gets all invoices that need review for a specific user.

  ## Parameters
    - user_id: The ID of the user whose invoices to retrieve
    - status: Optional filter by review status (default: "pending")

  ## Returns
    - List of ExtractedContent structs with associated review decisions
  """
  def get_invoices_for_review(user_id, status \\ "pending") do
    query =
      from ec in ExtractedContent,
      join: rd in ReviewDecision, on: rd.extracted_content_id == ec.id,
      where: ec.user_id == ^user_id,
      where: rd.review_status == ^status,
      order_by: ec.inserted_at

    Repo.all(query)
  end

  @doc """
  Gets the review status count for a user.

  ## Parameters
    - user_id: The ID of the user

  ## Returns
    - Map with counts by status: %{pending: int, approved: int, rejected: int, amended: int}
  """
  def get_review_status_counts(user_id) do
    ReviewDecision
    |> join(:left, [rd], ec in ExtractedContent, on: ec.id == rd.extracted_content_id)
    |> where([_, ec, rd], ec.user_id == ^user_id and rd.review_status in ["pending", "approved", "rejected", "amended"])
    |> group_by([_, _, rd], rd.review_status)
    |> select([_, _, rd], %{status: rd.review_status, count: count(rd.id)})
    |> Repo.all()
    |> Enum.into(%{}, fn %{status: status, count: count} -> {String.to_atom(status), count} end)
  end

  @doc """
  Approves an invoice after review.

  ## Parameters
    - invoice_id: The ID of the invoice to approve
    - user_id: The ID of the user approving
    - notes: Optional notes about the approval

  ## Returns
    - {:ok, review_decision} on success
    - {:error, reason} on failure
  """
  def approve_invoice(invoice_id, user_id, notes \\ nil) do
    with [:ok, %ExtractedContent{} = invoice] <- get_invoice_with_review(invoice_id, user_id),
         [:ok, review_decision] <- create_review_decision(invoice, user_id, "approved", %{}, notes) do
      emit_review_completed_event(invoice, review_decision, "approved")
      {:ok, review_decision}
    else
      error -> error
    end
  end

  @doc """
  Rejects an invoice after review.

  ## Parameters
    - invoice_id: The ID of the invoice to reject
    - user_id: The ID of the user rejecting
    - notes: Optional notes about the rejection

  ## Returns
    - {:ok, review_decision} on success
    - {:error, reason} on failure
  """
  def reject_invoice(invoice_id, user_id, notes \\ nil) do
    with [:ok, %ExtractedContent{} = invoice] <- get_invoice_with_review(invoice_id, user_id),
         [:ok, review_decision] <- create_review_decision(invoice, user_id, "rejected", %{}, notes) do
      emit_review_completed_event(invoice, review_decision, "rejected")
      {:ok, review_decision}
    else
      error -> error
    end
  end

  @doc """
  Amends an invoice with corrected data.

  ## Parameters
    - invoice_id: The ID of the invoice to amend
    - user_id: The ID of the user amending
    - amended_data: Map of corrected data
    - notes: Optional notes about the amendments

  ## Returns
    - {:ok, review_decision} on success
    - {:error, reason} on failure
  """
  def amend_invoice(invoice_id, user_id, amended_data, notes \\ nil) do
    with [:ok, %ExtractedContent{} = invoice] <- get_invoice_with_review(invoice_id, user_id),
         [:ok, review_decision] <- create_review_decision(invoice, user_id, "amended", amended_data, notes) do
      emit_review_completed_event(invoice, review_decision, "amended")
      {:ok, review_decision}
    else
      error -> error
    end
  end

  @doc """
  Handles document processing success event.

  ## Parameters
    - payload: The event payload from document_processing:success

  ## Returns
    - {:ok, review_decision} on success
    - {:error, reason} on failure
  """
  def handle_document_processing_success(payload) do
    extraction_id = payload["extraction_id"]
    user_id = payload["user_id"]

    case ZaimuTomo.DocumentProcessing.ExtractedContentContext.get_by_id(extraction_id) do
      nil ->
        {:error, "Extracted content not found for extraction ID: #{extraction_id}"}

      %ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent{} = content ->
        changeset =
          ReviewDecision.changeset_for_create(
            %ReviewDecision{
              extracted_content_id: content.id,
              user_id: user_id,
              review_status: "pending",
              decision_type: "initial",
              decision_data: %{},
              review_notes: "Automatically created from document processing",
              original_data: Map.from_struct(content.extracted_data)
            }
          )

        case Repo.insert(changeset) do
          {:ok, review_decision} -> {:ok, review_decision}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Handles document processing failure event.

  ## Parameters
    - payload: The event payload from document_processing:failure

  ## Returns
    - {:ok, extracted_content} on success
    - {:error, reason} on failure
  """
  def handle_document_processing_failure(payload) do
    extraction_id = payload["extraction_id"]
    _document_id = payload["document_id"]
    _error = payload["error"]
    user_id = payload["user_id"]

    case ZaimuTomo.DocumentProcessing.ExtractedContentContext.get_by_id(extraction_id) do
      nil ->
        {:error, "Extracted content not found for extraction ID: #{extraction_id}"}

      %ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent{} = content ->
        changeset =
          ReviewDecision.changeset_for_create(
            %ReviewDecision{
              extracted_content_id: content.id,
              user_id: user_id,
              review_status: "failed",
              decision_type: "failed",
              decision_data: %{},
              review_notes: "Automatically marked as failed from document processing"
            }
          )

        case Repo.insert(changeset) do
          {:ok, review_decision} -> {:ok, review_decision}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Lists all review decisions for a user, with pending ones first.

  ## Parameters
    - user_id: The ID of the user

  ## Returns
    - List of ReviewDecision structs with associated extracted content
  """
  def list_review_decisions(user_id) do
    query =
      from rd in ReviewDecision,
      join: ec in ExtractedContent, on: ec.id == rd.extracted_content_id,
      where: ec.user_id == ^user_id,
      order_by: [asc: rd.review_status == "pending", desc: rd.inserted_at]

    Repo.all(query)
  end

  @doc """
  Gets a review decision by ID.

  ## Parameters
    - id: The ID of the review decision
    - user_id: The ID of the user (for authorization)

  ## Returns
    - {:ok, review_decision} on success
    - {:error, reason} on failure
  """
  def get_review_decision(id, user_id) do
    query =
      from rd in ReviewDecision,
      join: ec in ExtractedContent, on: ec.id == rd.extracted_content_id,
      where: rd.id == ^id,
      where: ec.user_id == ^user_id

    case Repo.one(query) do
      nil -> {:error, "Review decision not found or not owned by user"}
      review_decision -> {:ok, review_decision}
    end
  end

  @doc """
  Updates a review decision with amended data.

  ## Parameters
    - %ReviewDecision{} = review_decision: The review decision to update
    - attrs: Map of attributes to update

  ## Returns
    - {:ok, updated_review_decision} on success
    - {:error, changeset} on validation error
  """
  def update_review_decision(%ReviewDecision{} = review_decision, attrs) do
    review_decision
    |> ReviewDecision.changeset_for_update(attrs)
    |> Repo.update()
  end

  defp get_invoice_with_review(invoice_id, user_id) do
    query =
      from ec in ExtractedContent,
      where: ec.id == ^invoice_id,
      where: ec.user_id == ^user_id

    case Repo.one(query) do
      nil -> {:error, "Invoice not found or not owned by user"}
      invoice -> {:ok, invoice}
    end
  end

  defp create_review_decision(invoice, user_id, decision_type, decision_data, notes) do
    changeset =
      ReviewDecision.changeset_for_create(
        %ReviewDecision{
          extracted_content_id: invoice.id,
          user_id: user_id,
          review_status: "completed",
          decision_type: decision_type,
          decision_data: decision_data,
          review_notes: notes,
          original_data: invoice.extracted_data
        }
      )

    Repo.insert(changeset)
  end

  defp emit_review_completed_event(invoice, review_decision, status) do
    payload = %{
      invoice_id: invoice.id,
      status: status,
      user_id: review_decision.user_id,
      decision_data: review_decision.decision_data,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "invoice_review:completed", payload)
  end
end
