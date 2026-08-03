defmodule ZaimuTomo.ReviewTest do
  use ZaimuTomo.DataCase

  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Review

  describe "reject_invoice/4" do
    test "requires and persists a rejection reason" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      extracted_content = extracted_content_fixture(document, user)
      {:ok, _} = Review.create_initial_decision(extracted_content)

      assert {:error, changeset} = Review.reject_invoice(extracted_content.id, user.id, "")
      assert %{rejection_reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, decision} =
               Review.reject_invoice(extracted_content.id, user.id, "Duplicate invoice")

      assert decision.review_status == "rejected"
      assert decision.rejection_reason == "Duplicate invoice"
    end
  end
end
