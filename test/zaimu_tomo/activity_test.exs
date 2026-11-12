defmodule ZaimuTomo.ActivityTest do
  use ZaimuTomo.DataCase

  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.Activity
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.Run

  setup do
    user = ZaimuTomo.AccountsFixtures.user_fixture()
    other_user = ZaimuTomo.AccountsFixtures.user_fixture()

    %{
      user: user,
      scope: Scope.for_user(user),
      other_scope: Scope.for_user(other_user),
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
    live_ocr_job(processing)

    review_document = document_fixture(scope, %{filename: "review.pdf"})
    review_content = extracted_content_fixture(review_document, user)
    pending_review_fixture(review_content)

    posted_document = document_fixture(scope, %{filename: "posted.pdf"})
    posted_content = extracted_content_fixture(posted_document, user)
    posted = approved_review_fixture(posted_content, user)
    book(posted, user)

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

    # The upload enqueues its job in the same transaction as the document.
    Repo.update_all(
      from(j in Oban.Job,
        where: fragment("?->>'document_id' = ?", j.args, ^to_string(processing.id))
      ),
      set: [inserted_at: ~U[2026-05-08 10:00:00Z]]
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

    assert %{status: "posted", filename: "posted.pdf"} = posted_item

    assert %{
             status: "review",
             filename: "review.pdf",
             merchant: "ACME Corp",
             amount_cents: 4200,
             currency: "EUR"
           } = review_item

    assert %{status: "processing", filename: "processing.pdf"} = processing_item
  end

  test "uses the document list's status for rejected and not yet booked invoices", %{
    scope: scope,
    user: user
  } do
    rejected_document = document_fixture(scope, %{filename: "rejected.pdf"})
    rejected_document |> extracted_content_fixture(user) |> rejected_review_fixture(user)

    unbooked_document = document_fixture(scope, %{filename: "unbooked.pdf"})

    unbooked_document
    |> extracted_content_fixture(user, %{
      extracted_data: %{
        amount_to_pay_cents: 100,
        invoice_date: "2026-01-01",
        currency: "CHF",
        reason_for_payment: "Other",
        issuer: "Other AG"
      }
    })
    |> approved_review_fixture(user)

    statuses = Map.new(Activity.list_recent(scope, limit: :all), &{&1.filename, &1.status})

    assert statuses == %{"rejected.pdf" => "rejected", "unbooked.pdf" => "review"}
  end

  test "takes processing, stalled and failed from the job queue, like the document list", %{
    scope: scope,
    user: user
  } do
    document_fixture(scope, %{filename: "stalled.pdf"})

    retrying = document_fixture(scope, %{filename: "retrying.pdf"})
    extracted_content_fixture(retrying, user, %{status: "failed"})
    live_ocr_job(retrying)

    reprocessing = document_fixture(scope, %{filename: "reprocessing.pdf"})
    reprocessing |> extracted_content_fixture(user) |> pending_review_fixture()
    live_ocr_job(reprocessing)

    statuses = Map.new(Activity.list_recent(scope, limit: :all), &{&1.filename, &1.status})

    assert statuses == %{
             "stalled.pdf" => "stalled",
             "retrying.pdf" => "processing",
             "reprocessing.pdf" => "processing"
           }
  end

  test "a retried document carries its run and moves above newer activity", %{
    scope: scope,
    user: user
  } do
    retried = document_fixture(scope, %{filename: "retried.pdf"})
    failed_content = extracted_content_fixture(retried, user, %{status: "failed"})

    newer = document_fixture(scope, %{filename: "newer.pdf"})
    newer_content = extracted_content_fixture(newer, user)
    pending_review_fixture(newer_content)

    set_updated_at(failed_content, -7200)
    set_updated_at(newer_content, -60)

    assert [%{filename: "newer.pdf"}, %{filename: "retried.pdf", status: "failed", run: nil}] =
             Activity.list_recent(scope, limit: :all)

    assert {:ok, _job} = DocumentProcessing.retry_document(scope, retried)

    assert [
             %{filename: "retried.pdf", status: "processing", run: %Run{trigger: :manual_retry}},
             %{filename: "newer.pdf", status: "review", run: nil}
           ] = Activity.list_recent(scope, limit: :all)
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

  defp set_updated_at(content, seconds_from_now) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), seconds_from_now)

    Repo.update_all(from(ec in ExtractedContent, where: ec.id == ^content.id),
      set: [updated_at: at]
    )
  end

  defp live_ocr_job(document),
    do: document |> DocumentProcessing.ocr_job("CHF", nil) |> Oban.insert!()

  defp book(review, user) do
    {:ok, entry} = ZaimuTomo.Accounting.get_journal_entry_for_decision(review.id)
    {:ok, _} = ZaimuTomo.Accounting.post_entry(entry, user.id, "Office", "need")
  end
end
