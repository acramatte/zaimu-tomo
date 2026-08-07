defmodule ZaimuTomoWeb.SpendingLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  test "renders current-month spending with comparison and trend", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    today = Date.utc_today()
    current_month = Calendar.strftime(today, "%B %Y")

    create_entry(scope, user, today, 12_345, "EUR", "Software")
    create_entry(scope, user, today, 5_000, "EUR", "Transport")

    {:ok, _live, html} = live(conn, ~p"/spending")

    assert html =~ "Spending history"
    assert html =~ "#{current_month} spending"
    assert html =~ "Compared with"
    assert html =~ "CHF 173.45"
    assert html =~ "Software"
    assert html =~ "Transport"
    assert html =~ "Last 6 months"
    assert html =~ "spending-bar-chart"
  end

  test "shows the requested month via the month query param", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    create_entry(scope, user, ~D[2026-03-15], 9_999, "EUR", "Software")

    {:ok, _live, html} = live(conn, ~p"/spending?month=2026-03")

    assert html =~ "March 2026 spending"
    assert html =~ "CHF 99.99"
  end

  test "falls back to the current month for an invalid month param", %{conn: conn} do
    current_month = Calendar.strftime(Date.utc_today(), "%B %Y")

    {:ok, _live, html} = live(conn, ~p"/spending?month=not-a-month")

    assert html =~ "#{current_month} spending"
  end

  test "clamps a future month to the current month", %{conn: conn} do
    current_month = Calendar.strftime(Date.utc_today(), "%B %Y")

    {:ok, _live, html} = live(conn, ~p"/spending?month=2099-01")

    assert html =~ "#{current_month} spending"
  end

  test "navigates between months with prev/next patch links", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    create_entry(scope, user, ~D[2026-03-15], 9_999, "EUR", "Software")

    {:ok, _live, html} = live(conn, ~p"/spending?month=2026-04")

    assert html =~ "April 2026 spending"

    # previous month link goes back to March
    prev_href = href_for(html, "Previous month")
    assert prev_href =~ "month=2026-03"

    {:ok, _live, html} = live(conn, prev_href)
    assert html =~ "March 2026 spending"
    assert html =~ "CHF 99.99"

    # next month link comes back forward
    next_href = href_for(html, "Next month")
    assert next_href =~ "month=2026-04"
  end

  test "hides next-month navigation on the current month", %{conn: conn} do
    {:ok, live, html} = live(conn, ~p"/spending")

    assert html =~ "→ next"
    refute html =~ "Next month"
    assert has_element?(live, "span.btn.disabled")
  end

  test "shows an empty state when the month has no categorized spending", %{
    conn: conn
  } do
    {:ok, _live, html} = live(conn, ~p"/spending?month=2026-01")

    assert html =~ "No categorized spending in January 2026"
  end

  test "shows a history empty state when no spending exists at all", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    create_entry(scope, user, Date.utc_today(), 12_345, "EUR", "Software")

    {:ok, _live, html} = live(conn, ~p"/spending?month=2020-01")

    assert html =~ "No spending recorded yet"
    refute html =~ "history-chart"
  end

  defp href_for(html, aria_label) do
    tag =
      Regex.run(~r/<a[^>]*aria-label="#{aria_label}"[^>]*>/, html)
      |> List.first()

    Regex.run(~r/href="([^"]+)"/, tag, capture: :all_but_first)
    |> List.first()
  end

  defp create_entry(scope, user, date, amount_cents, currency, category) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    {:ok, entry} = Accounting.create_from_decision(decision)

    entry =
      entry
      |> Ecto.Changeset.change(
        date: date,
        amount_cents: amount_cents,
        currency: currency
      )
      |> Repo.update!()

    {:ok, entry} = Accounting.post_entry(entry, user.id, category, "need")
    entry
  end
end
