defmodule ZaimuTomo.ActivityTest do
  use ZaimuTomo.DataCase

  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Activity

  setup do
    user = ZaimuTomo.AccountsFixtures.user_fixture()
    other_user = ZaimuTomo.AccountsFixtures.user_fixture()

    %{
      user: user,
      scope: ZaimuTomo.Accounts.Scope.for_user(user),
      other_scope: ZaimuTomo.Accounts.Scope.for_user(other_user),
      other_user: other_user
    }
  end

  test "returns user-scoped workflow statuses ordered by their latest transition", %{
    scope: scope,
    user: user,
    other_scope: other_scope,
    other_user: other_user
  } do
    processing = document_fixture(scope, %{filename: "processing.pdf"})

    review_document = document_fixture(scope, %{filename: "review.pdf"})
    review_content = extracted_content_fixture(review_document, user)
    review = pending_review_fixture(review_content)

    posted_document = document_fixture(scope, %{filename: "posted.pdf"})
    posted_content = extracted_content_fixture(posted_document, user)
    posted = approved_review_fixture(posted_content, user)

    failed_document = document_fixture(scope, %{filename: "failed.pdf"})

    failed_content =
      extracted_content_fixture(failed_document, user, %{
        status: "failed",
        error_details: %{"message" => "Image too blurry"}
      })

    other_document = document_fixture(other_scope, %{filename: "other-user.pdf"})
    other_content = extracted_content_fixture(other_document, other_user)
    pending_review_fixture(other_content)

    Repo.update_all(from(d in ZaimuTomo.Documents.Document, where: d.id == ^processing.id),
      set: [updated_at: ~U[2026-05-08 10:00:00Z]]
    )

    Repo.update_all(
      from(ec in ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent,
        where: ec.id == ^review_content.id
      ),
      set: [updated_at: ~N[2026-05-08 11:00:00]]
    )

    Repo.update_all(
      from(rd in ZaimuTomo.Review.ReviewDecision, where: rd.id == ^posted.id),
      set: [review_completed_at: ~U[2026-05-08 12:00:00Z], updated_at: ~N[2026-05-08 12:00:00]]
    )

    Repo.update_all(
      from(ec in ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent,
        where: ec.id == ^failed_content.id
      ),
      set: [updated_at: ~N[2026-05-08 13:00:00]]
    )

    assert [failed_item, posted_item, review_item, processing_item] =
             Activity.list_recent(scope, limit: :all)

    assert %{status: "failed", filename: "failed.pdf", error: "Image too blurry"} = failed_item

    posted_id = posted.id
    review_id = review.id

    assert %{status: "posted", filename: "posted.pdf", review_id: ^posted_id} = posted_item

    assert %{
             status: "review",
             filename: "review.pdf",
             merchant: "ACME Corp",
             amount_cents: 4200,
             currency: "EUR",
             review_id: ^review_id
           } = review_item

    assert %{status: "processing", filename: "processing.pdf", review_id: nil} = processing_item
  end

  test "limits the feed after ordering activity", %{scope: scope} do
    first = document_fixture(scope, %{filename: "first.pdf"})
    second = document_fixture(scope, %{filename: "second.pdf"})

    Repo.update_all(from(d in ZaimuTomo.Documents.Document, where: d.id == ^first.id),
      set: [updated_at: ~U[2026-05-08 10:00:00Z]]
    )

    Repo.update_all(from(d in ZaimuTomo.Documents.Document, where: d.id == ^second.id),
      set: [updated_at: ~U[2026-05-08 11:00:00Z]]
    )

    assert [%{filename: "second.pdf"}] = Activity.list_recent(scope, limit: 1)
  end
end
