defmodule ZaimuTomo.DocumentProcessing.WorkerTest do
  use ZaimuTomo.DataCase, async: true

  alias ZaimuTomo.DocumentProcessing.Worker
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures

  describe "persist_and_emit_success/2" do
    test "includes user_id from document in extracted content" do
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

      {:ok, content} = Worker.persist_and_emit_success(document, extracted_data)

      assert content.user_id == user.id
      assert content.document_id == document.id
      assert content.status == "success"
    end
  end
end
