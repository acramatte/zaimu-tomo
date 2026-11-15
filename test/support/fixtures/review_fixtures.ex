defmodule ZaimuTomo.ReviewFixtures do
  @moduledoc false
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentsFixtures
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review

  @valid_extracted_data %{
    amount_to_pay_cents: 4200,
    invoice_date: "2026-05-08",
    invoice_number: nil,
    currency: "EUR",
    reason_for_payment: "Office supplies",
    issuer: "ACME Corp"
  }

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
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    Repo.get!(ExtractedContent, row.id)
    |> Repo.preload(:review_decision)
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

  @doc """
  Approves an invoice with `attrs` over the default extracted data and a
  unique invoice number, and returns its journal entry: posted with a
  booking, or still uncategorized with `post: false`.
  """
  def journal_entry_fixture(scope, attrs \\ %{}, opts \\ []) do
    document =
      DocumentsFixtures.document_fixture(scope, %{
        object_key: "documents/#{System.unique_integer([:positive])}.pdf"
      })

    data =
      @valid_extracted_data
      |> Map.put(:invoice_number, "INV-#{System.unique_integer([:positive])}")
      |> Map.merge(Map.new(attrs))

    content = extracted_content_fixture(document, scope.user, %{extracted_data: data})
    {:ok, _} = Review.create_initial_decision(content)

    booking =
      if Keyword.get(opts, :post, true),
        do: [booking: %{category: "Office", need_or_want: "need"}],
        else: []

    {:ok, decision} = Review.approve_invoice(content.id, scope.user.id, nil, booking)
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
    entry
  end
end
