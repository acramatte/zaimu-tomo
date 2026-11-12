defmodule ZaimuTomoWeb.ActivityLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents

  setup :register_and_log_in_user

  test "shows the user's documents and not another user's", %{conn: conn, scope: scope} do
    document_fixture(scope, %{filename: "mine.pdf"})

    other_scope = Scope.for_user(ZaimuTomo.AccountsFixtures.user_fixture())
    document_fixture(other_scope, %{filename: "theirs.pdf"})

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-feed", "mine.pdf")
    refute render(view) =~ "theirs.pdf"
  end

  test "filters by status tab and counts each tab", %{conn: conn, scope: scope, user: user} do
    processing = document_fixture(scope, %{filename: "processing.pdf"})
    live_ocr_job(processing)

    review = document_fixture(scope, %{filename: "review.pdf"})
    review |> extracted_content_fixture(user) |> pending_review_fixture()

    posted = document_fixture(scope, %{filename: "posted.pdf"})
    posted |> extracted_content_fixture(user) |> approved_review_fixture(user) |> book(user)

    failed = document_fixture(scope, %{filename: "failed.pdf"})
    extracted_content_fixture(failed, user, %{status: "failed"})

    document_fixture(scope, %{filename: "stalled.pdf"})

    rejected = document_fixture(scope, %{filename: "rejected.pdf"})
    rejected |> extracted_content_fixture(user) |> rejected_review_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/activity")

    for {tab, count} <- [
          {"all", 6},
          {"review", 1},
          {"processing", 1},
          {"failed", 2},
          {"posted", 1},
          {"rejected", 1}
        ] do
      assert view |> element("#activity-tabs a[href$='#{tab_href(tab)}'] .count") |> render() =~
               ">#{count}<"
    end

    view |> element("#activity-tabs a", "Failed") |> render_click()

    assert_patch(view, ~p"/activity?tab=failed")
    assert has_element?(view, "#activity-tabs a[aria-current=page]", "Failed")
    assert has_element?(view, "#activity-feed", "failed.pdf")
    assert has_element?(view, "#activity-feed", "stalled.pdf")
    refute has_element?(view, "#activity-feed", "review.pdf")
    refute has_element?(view, "#activity-feed", "posted.pdf")
  end

  test "falls back to all for an unknown tab", %{conn: conn, scope: scope} do
    document_fixture(scope, %{filename: "stalled.pdf"})

    {:ok, view, _html} = live(conn, ~p"/activity?tab=bogus")

    assert has_element?(view, "#activity-tabs a[aria-current=page]", "All")
    assert has_element?(view, "#activity-feed", "stalled.pdf")
  end

  test "renders an empty state with an upload link when there are no documents", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-empty a[href='/documents/new']")
    refute has_element?(view, "#activity-feed")
  end

  test "renders a filter empty state when a tab has no documents", %{conn: conn, scope: scope} do
    document_fixture(scope, %{filename: "stalled.pdf"})

    {:ok, view, _html} = live(conn, ~p"/activity?tab=posted")

    assert has_element?(view, "#activity-tab-empty")
    refute has_element?(view, "#activity-empty")
    refute has_element?(view, "#activity-feed")
  end

  test "adds a newly created document to the feed live", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/activity")
    assert has_element?(view, "#activity-empty")

    {:ok, _document} =
      Documents.create_document(scope, %{filename: "fresh.pdf", object_key: "documents/fresh.pdf"})

    assert has_element?(view, "#activity-feed", "fresh.pdf")
    assert has_element?(view, "#activity-tabs a[href$='/activity?tab=processing'] .count", "1")
  end

  test "a success broadcast before the job is acknowledged ends in Needs review",
       %{conn: conn, scope: scope} do
    {:ok, doc} =
      Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

    set_job_state(doc, "executing")
    {:ok, view, _html} = live(conn, ~p"/activity")
    assert has_element?(view, "#activity-tabs a[href$='/activity?tab=processing'] .count", "1")

    {:ok, _content} =
      ZaimuTomo.DocumentProcessing.Worker.persist_and_emit_success(
        doc,
        %{
          "amount_to_pay_cents" => 4200,
          "invoice_date" => "2026-05-08",
          "invoice_number" => "INV-1",
          "currency" => "CHF",
          "reason_for_payment" => "Office supplies",
          "issuer" => "ACME Corp"
        },
        %{},
        %{},
        nil,
        "CHF"
      )

    _ = render(view)
    assert has_element?(view, "#activity-tabs a[href$='/activity?tab=processing'] .count", "1")

    set_job_state(doc, "completed")

    await(view, "#activity-tabs a[href$='/activity?tab=review'] .count", "1")
    assert has_element?(view, "#activity-tabs a[href$='/activity?tab=processing'] .count", "0")
  end

  defp set_job_state(doc, state) do
    import Ecto.Query

    {1, _} =
      from(j in Oban.Job, where: j.worker == "ZaimuTomo.DocumentProcessing.OCRJob")
      |> where([j], fragment("?->>'document_id' = ?", j.args, ^to_string(doc.id)))
      |> ZaimuTomo.Repo.update_all(set: [state: state])
  end

  defp await(view, selector, text, attempts \\ 40) do
    cond do
      has_element?(view, selector, text) -> :ok
      attempts == 0 -> flunk("expected #{selector} with #{text}, got: #{render(view)}")
      true -> Process.sleep(25) && await(view, selector, text, attempts - 1)
    end
  end

  defp tab_href("all"), do: "/activity"
  defp tab_href(tab), do: "/activity?tab=#{tab}"

  defp live_ocr_job(document),
    do: document |> DocumentProcessing.ocr_job("CHF", nil) |> Oban.insert!()

  defp book(review, user) do
    {:ok, entry} = ZaimuTomo.Accounting.get_journal_entry_for_decision(review.id)
    {:ok, _} = ZaimuTomo.Accounting.post_entry(entry, user.id, "Office", "need")
  end
end
