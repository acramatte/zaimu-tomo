defmodule ZaimuTomoWeb.FinancialAccountLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.FinancialAccountsFixtures

  alias ZaimuTomoWeb.FinancialAccountHistory

  setup :register_and_log_in_user

  test "creates a financial account with its initial balance", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/accounts")
    assert html =~ "No financial accounts yet"

    view
    |> form("#financial-account-form", %{
      "account" => %{
        "name" => "Emergency fund",
        "account_type" => "savings",
        "currency" => "usd",
        "bank_name" => "Raiffeisen",
        "account_number" => "example-account-1234",
        "balance" => "123.45",
        "recorded_on" => "2026-07-28"
      }
    })
    |> render_submit()

    assert render(view) =~ "Emergency fund"
    assert render(view) =~ "USD 123.45"
    assert render(view) =~ "Raiffeisen"
  end

  test "plots a twelve-month balance trend grouped by currency and toggles accounts", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()

    everyday =
      financial_account_fixture(scope, %{
        name: "Everyday",
        amount_cents: 10_000,
        recorded_on: today
      })

    savings =
      financial_account_fixture(scope, %{
        name: "Savings",
        amount_cents: 20_000,
        recorded_on: today
      })

    brokerage =
      financial_account_fixture(scope, %{
        name: "Brokerage",
        currency: "USD",
        amount_cents: 30_000,
        recorded_on: today
      })

    previous_month_end = Date.add(Date.beginning_of_month(today), -1)

    balance_snapshot_fixture(scope, everyday, %{
      amount_cents: 8_000,
      recorded_on: previous_month_end
    })

    balance_snapshot_fixture(scope, savings, %{
      amount_cents: 15_000,
      recorded_on: previous_month_end
    })

    {:ok, view, html} = live(conn, ~p"/accounts")

    assert html =~ FinancialAccountHistory.period_label(today)
    assert :binary.match(html, "Your accounts") < :binary.match(html, "Add financial account")

    assert :binary.match(html, "Add financial account") <
             :binary.match(html, "id=\"account-balance-history\"")

    assert has_element?(view, "#balance-trend-eur")
    assert has_element?(view, "#balance-trend-usd")
    assert has_element?(view, "#balance-trend-eur [data-account-series='#{everyday.id}']")
    assert has_element?(view, "#balance-trend-eur [data-account-series='#{savings.id}']")

    assert has_element?(
             view,
             "#balance-trend-eur polyline.balance-trend-total[data-account-series='total-EUR']"
           )

    assert has_element?(view, "#balance-trend-eur .balance-trend-point.tooltip-edge-end")
    assert has_element?(view, "#balance-trend-eur polyline[data-account-series='#{everyday.id}']")
    assert has_element?(view, "#balance-trend-eur polyline[data-account-series='#{savings.id}']")
    assert has_element?(view, "#balance-trend-usd [data-account-series='#{brokerage.id}']")

    view
    |> element("#account-series-toggle-#{everyday.id}")
    |> render_click()

    refute has_element?(view, "#balance-trend-eur [data-account-series='#{everyday.id}']")
    assert has_element?(view, "#balance-trend-eur [data-account-series='#{savings.id}']")
    assert has_element?(view, "#balance-trend-usd [data-account-series='#{brokerage.id}']")
    assert has_element?(view, "#account-series-toggle-#{everyday.id}[aria-pressed='false']")

    assert has_element?(
             view,
             "#balance-trend-eur [data-account-series='total-EUR'][aria-label*='EUR 300.00']"
           )

    assert has_element?(
             view,
             "#balance-trend-usd [data-account-series='total-USD'][aria-label*='USD 300.00']"
           )

    view
    |> element("#account-series-toggle-#{savings.id}")
    |> render_click()

    assert has_element?(view, "#balance-currency-eur .empty-state", "All EUR accounts are hidden")

    assert has_element?(
             view,
             "#balance-trend-eur [data-account-series='total-EUR'][aria-label*='EUR 300.00']"
           )

    view
    |> element("#account-series-toggle-#{everyday.id}")
    |> render_click()

    assert has_element?(view, "#balance-trend-eur [data-account-series='#{everyday.id}']")
    refute has_element?(view, "#balance-trend-eur [data-account-series='#{savings.id}']")
  end

  test "shows only the selected account's balance series on its detail route", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()
    account = financial_account_fixture(scope, %{name: "Everyday", recorded_on: today})
    other_account = financial_account_fixture(scope, %{name: "Savings", recorded_on: today})

    {:ok, view, html} = live(conn, ~p"/accounts/#{account}")

    assert html =~ FinancialAccountHistory.period_label(today)
    assert has_element?(view, "#balance-trend-account-#{account.id}")

    assert has_element?(
             view,
             "#balance-trend-account-#{account.id} [data-account-series='#{account.id}']"
           )

    refute has_element?(
             view,
             "#balance-trend-account-#{account.id} [data-account-series='#{other_account.id}']"
           )
  end

  test "connects sparse balances and uses pre-window balances for currency totals", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()
    first_month = FinancialAccountHistory.first_month(today)
    pre_window = Date.add(first_month, -1)
    gap_month = ZaimuTomoWeb.Spending.shift_month(first_month, 2)

    account =
      financial_account_fixture(scope, %{
        name: "Sparse",
        recorded_on: first_month,
        amount_cents: 1_000
      })

    balance_snapshot_fixture(scope, account, %{recorded_on: gap_month, amount_cents: 2_000})

    financial_account_fixture(scope, %{
      name: "Unchanged",
      recorded_on: pre_window,
      amount_cents: 5_000
    })

    other_scope = ZaimuTomo.AccountsFixtures.user_scope_fixture()

    private =
      financial_account_fixture(other_scope, %{
        name: "Private",
        recorded_on: today,
        amount_cents: 99_999
      })

    {:ok, overview, _} = live(conn, ~p"/accounts")

    assert has_element?(
             overview,
             "#balance-trend-eur polyline[data-account-series='#{account.id}']"
           )

    assert has_element?(
             overview,
             "#balance-trend-eur [data-account-series='total-EUR'][aria-label*='EUR 70.00']"
           )

    refute has_element?(overview, "[data-account-series='#{private.id}']")

    {:ok, detail, _} = live(conn, ~p"/accounts/#{account}")

    assert has_element?(
             detail,
             "#balance-trend-account-#{account.id} polyline[data-account-series='#{account.id}']"
           )

    assert length(Regex.scan(~r/class="line-point balance-trend-point/, render(detail))) == 2
  end

  test "suppresses an incomplete currency total without suppressing known account points", %{
    conn: conn,
    scope: scope
  } do
    today = Date.utc_today()
    financial_account_fixture(scope, %{name: "Known", recorded_on: today})
    financial_account_fixture(scope, %{name: "Not yet known", recorded_on: Date.add(today, 1)})
    {:ok, view, _} = live(conn, ~p"/accounts")
    assert has_element?(view, "#balance-trend-eur .balance-trend-point")
    refute has_element?(view, "#balance-trend-eur [data-account-series='total-EUR']")
  end

  test "records a dated balance snapshot", %{conn: conn, scope: scope} do
    account =
      financial_account_fixture(scope, %{
        name: "Emergency fund",
        amount_cents: 10_000,
        bank_name: "Raiffeisen",
        account_number: "example-account-1234"
      })

    {:ok, view, html} = live(conn, ~p"/accounts/#{account}")
    assert html =~ "EUR 100.00"
    assert html =~ "Raiffeisen"
    assert html =~ "example-account-1234"

    view
    |> form("#record-balance-form", %{
      "balance" => %{"balance" => "123.45", "recorded_on" => "2026-07-29"}
    })
    |> render_submit()

    assert render(view) =~ "EUR 123.45"
    assert render(view) =~ "2026-07-29"
  end

  test "shows a validation error for an amount with more than two decimals", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/accounts")

    view
    |> form("#financial-account-form", %{
      "account" => %{
        "name" => "Emergency fund",
        "account_type" => "savings",
        "currency" => "EUR",
        "balance" => "12.345",
        "recorded_on" => "2026-07-28"
      }
    })
    |> render_submit()

    assert render(view) =~ "must have at most two decimal places"
  end
end
