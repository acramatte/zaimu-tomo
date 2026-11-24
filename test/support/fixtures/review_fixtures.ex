defmodule ZaimuTomo.ReviewFixtures do
  @moduledoc false
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review

  import Ecto.Query, only: [from: 2]

  @valid_extracted_data %{
    amount_to_pay_cents: 4200,
    invoice_date: "2026-05-08",
    invoice_number: nil,
    currency: "EUR",
    reason_for_payment: "Office supplies",
    issuer: "ACME Corp"
  }

  @doc """
  Inserts an extraction row. A success row is inserted pending, as the
  database requires, then moved to `attrs[:verification_status]`, the status
  in `attrs[:analysis]["verification"]`, or `"verified"`; pass
  `verification_status: "pending"` to keep it pending.
  """
  def extracted_content_fixture(document, user, attrs \\ %{}) do
    status = Map.get(attrs, :status, "success")

    # For failed extractions the changeset skips extracted_data validation
    # but the DB column is NOT NULL, so we bypass the changeset and insert directly.
    extracted_data =
      if status == "success" do
        Map.get(attrs, :extracted_data, @valid_extracted_data)
      else
        %{}
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()

    {1, [row]} =
      Repo.insert_all(
        "extracted_content",
        [
          %{
            document_id: document.id,
            user_id: user.id,
            status: status,
            extracted_data: extracted_data,
            raw_llm_response: Map.get(attrs, :raw_llm_response),
            trace_id: Map.get(attrs, :trace_id),
            analysis: Map.get(attrs, :analysis),
            error_details: Map.get(attrs, :error_details),
            verification_status: if(status == "success", do: "pending"),
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    with "success" <- status,
         verification_status when verification_status != "pending" <-
           fixture_verification_status(attrs) do
      Repo.update_all(from(ec in "extracted_content", where: ec.id == ^row.id),
        set: [verification_status: verification_status]
      )
    end

    Repo.get!(ExtractedContent, row.id)
    |> Repo.preload(:review_decision)
  end

  defp fixture_verification_status(attrs) do
    attrs[:verification_status] ||
      get_in(attrs, [:analysis, "verification", "status"]) ||
      "verified"
  end

  def pending_review_fixture(extracted_content) do
    {:ok, decision} = Review.create_initial_decision(extracted_content)
    decision
  end

  def approved_review_fixture(extracted_content, user) do
    {:ok, _} = Review.create_initial_decision(extracted_content)
    {:ok, decision} = Review.approve_invoice(extracted_content.id, user.id)
    decision
  end

  def rejected_review_fixture(extracted_content, user) do
    {:ok, _} = Review.create_initial_decision(extracted_content)
    {:ok, decision} = Review.reject_invoice(extracted_content.id, user.id, "Duplicate invoice")
    decision
  end

  def amended_review_fixture(extracted_content, user) do
    {:ok, _} = Review.create_initial_decision(extracted_content)
    {:ok, decision} = Review.amend_invoice(extracted_content.id, user.id, @valid_extracted_data)
    decision
  end
end
