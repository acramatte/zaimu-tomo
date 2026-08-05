defmodule ZaimuTomo.DocumentProcessing.WorkerTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.DocumentProcessing.Worker
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Repo
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]

  describe "persist_and_emit_success/3" do
    test "includes user_id from document in extracted content and stores raw response" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      raw_llm_response = %{"amount_to_pay_cents" => 1000, "issuer" => "Test Issuer"}

      {:ok, content} = Worker.persist_and_emit_success(document, extracted_data, raw_llm_response)

      assert content.user_id == user.id
      assert content.document_id == document.id
      assert content.status == "success"
      assert content.raw_llm_response == raw_llm_response
      assert content.analysis["verification"]["status"] == "not_run"
      assert content.trace_id == nil
    end

    test "persists the Langfuse trace id when provided" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      {:ok, content} =
        Worker.persist_and_emit_success(
          document,
          extracted_data,
          %{},
          %{"status" => "verified"},
          "abc123def456abc123def456abc123def4"
        )

      assert content.trace_id == "abc123def456abc123def456abc123def4"
    end

    test "stores verifier analysis when provided" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      raw_llm_response = %{"pages" => []}
      verification = %{"status" => "needs_review", "raw_response" => "NEEDS_REVIEW"}

      {:ok, content} =
        Worker.persist_and_emit_success(document, extracted_data, raw_llm_response, verification)

      assert content.status == "success"
      assert content.analysis["verification"] == verification
    end
  end

  describe "persist_and_emit_failure/2" do
    test "persists failed OCR attempts without extracted invoice data" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      assert {:ok, content} =
               Worker.persist_and_emit_failure(
                 document,
                 {:ocr_upload_failed, "Missing Mistral API key"}
               )

      assert content.user_id == user.id
      assert content.document_id == document.id
      assert content.status == "failed"
      assert content.extracted_data.amount_to_pay_cents == nil
      assert content.extracted_data.invoice_date == nil
      assert content.error_details["type"] == "ocr_upload_failed"
      assert content.error_details["message"] == "Missing Mistral API key"
    end

    test "persists a failed review when the error reason exceeds the review notes limit" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      assert {:ok, content} =
               Worker.persist_and_emit_failure(
                 document,
                 {:llm_request_failed, String.duplicate("connection refused ", 100)}
               )

      review_decision = Repo.get_by!(ReviewDecision, extracted_content_id: content.id)

      assert review_decision.review_notes ==
               "Automatically marked as failed: llm_request_failed"
    end
  end

  defp document_fixture(scope, attrs) do
    attrs =
      Enum.into(attrs, %{
        filename: "some filename",
        filepath: "some filepath",
        user_id: scope.user.id
      })

    Repo.insert!(struct!(Document, attrs))
  end
end
