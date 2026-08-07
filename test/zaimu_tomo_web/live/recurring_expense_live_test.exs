defmodule ZaimuTomoWeb.RecurringExpenseLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Ecto.Changeset
  import Phoenix.LiveViewTest
  import ZaimuTomo.RecurringExpensesFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  test "creates a recurring expense", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/recurring")
    assert html =~ "No recurring expenses yet"

    view
    |> form("#recurring-expense-form", %{
      "recurring_expense" => %{
        "name" => "Spotify family",
        "amount" => "17.99",
        "currency" => "eur",
        "frequency" => "monthly",
        "start_date" => "2026-01-28",
        "end_date" => ""
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Spotify family"
    assert html =~ "EUR 17.99"
    assert html =~ "Monthly"
  end

  test "validates that the end date is not before the start date", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recurring")

    view
    |> form("#recurring-expense-form", %{
      "recurring_expense" => %{
        "name" => "Rent",
        "amount" => "1180.00",
        "currency" => "EUR",
        "frequency" => "monthly",
        "start_date" => "2026-01-15",
        "end_date" => "2026-01-01"
      }
    })
    |> render_submit()

    assert render(view) =~ "must be on or after the start date"
  end

  test "edits an existing recurring expense", %{conn: conn, scope: scope} do
    expense = recurring_expense_fixture(scope, %{name: "Rent", amount_cents: 118_000})
    {:ok, view, _html} = live(conn, ~p"/recurring")

    view |> element("#recurring-#{expense.id} button", "Edit") |> render_click()

    html = render(view)
    assert html =~ "Edit recurring expense"
    assert html =~ "1180.00"

    view
    |> form("#recurring-expense-form", %{
      "recurring_expense" => %{
        "name" => "Rent · Av. Louise",
        "amount" => "1250.00",
        "currency" => "EUR",
        "frequency" => "monthly",
        "start_date" => "2026-01-15",
        "end_date" => "2027-01-01"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Rent · Av. Louise"
    assert html =~ "EUR 1,250.00"
    assert html =~ "until 2027-01-01"
  end

  test "deletes a recurring expense", %{conn: conn, scope: scope} do
    expense = recurring_expense_fixture(scope, %{name: "Old gym"})
    {:ok, view, _html} = live(conn, ~p"/recurring")

    assert render(view) =~ "Old gym"

    render_click(view, "delete", %{"id" => expense.id})

    refute render(view) =~ "Old gym"
    assert render(view) =~ "No recurring expenses yet"
  end

  test "links an uploaded invoice to the next occurrence and unlinks it", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    expense =
      recurring_expense_fixture(scope, %{
        name: "Spotify",
        amount_cents: 1_799,
        start_date: today
      })

    entry = create_entry(scope, today, 1_799)

    {:ok, view, _html} = live(conn, ~p"/recurring")

    assert render(view) =~ "candidate-#{expense.id}-#{entry.id}"

    view |> element("#candidate-#{expense.id}-#{entry.id} button", "Link") |> render_click()

    html = render(view)
    assert html =~ "Covered by"
    assert html =~ "Unlink"

    view |> element("#reconcile-covered-#{expense.id} button", "Unlink") |> render_click()

    html = render(view)
    refute html =~ "Covered by"
    # the entry becomes a linkable candidate again
    assert html =~ "candidate-#{expense.id}-#{entry.id}"
  end

  defp create_entry(scope, date, amount_cents) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, scope.user)
    decision = approved_review_fixture(extracted_content, scope.user)
    {:ok, entry} = Accounting.create_from_decision(decision)
    entry |> change(date: date, amount_cents: amount_cents) |> Repo.update!()
  end
end
