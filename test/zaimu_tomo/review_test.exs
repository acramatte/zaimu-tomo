defmodule ZaimuTomo.ReviewTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.Review
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 1]

  import ZaimuTomo.ReviewFixtures,
    only: [
      approved_review_fixture: 2,
      extracted_content_fixture: 2,
      extracted_content_fixture: 3,
      pending_review_fixture: 1
    ]

  setup do
    original_config = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    on_exit(fn ->
      if original_config do
        Application.put_env(:zaimu_tomo, :langfuse, original_config)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)
  end

  describe "submit_extraction_feedback/4" do
    test "returns an error when the extracted content does not belong to the user" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user, %{trace_id: "trace-abc"})
      other_user = user_fixture()

      assert {:error, "Extracted content not found or not owned by user"} =
               Review.submit_extraction_feedback(content.id, other_user.id, 0, "wrong amount")
    end

    test "returns an error when no Langfuse trace was recorded for the extraction" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user)

      assert {:error, "No Langfuse trace recorded for this extraction"} =
               Review.submit_extraction_feedback(content.id, user.id, 1)
    end

    test "records a score on the extraction's Langfuse trace" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      content = extracted_content_fixture(document, user, %{trace_id: "trace-abc"})
      parent = self()

      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        score_sender: fn payload ->
          send(parent, {:score_payload, payload})
          {:ok, %{status: 200}}
        end
      )

      assert :ok =
               Review.submit_extraction_feedback(content.id, user.id, 0, "amount was wrong")

      assert_received {:score_payload, payload}
      assert payload.traceId == "trace-abc"
      assert payload.value == 0
      assert payload.comment == "amount was wrong"
    end
  end

  describe "pending_review_count/1" do
    test "counts only pending reviews owned by the scope" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      pending_document = document_fixture(scope)
      pending_document |> extracted_content_fixture(user) |> pending_review_fixture()

      approved_document = document_fixture(scope)
      approved_document |> extracted_content_fixture(user) |> approved_review_fixture(user)

      other_user = user_fixture()
      other_scope = user_scope_fixture(other_user)
      other_document = document_fixture(other_scope)
      other_document |> extracted_content_fixture(other_user) |> pending_review_fixture()

      assert Review.pending_review_count(scope) == 1
    end
  end

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
