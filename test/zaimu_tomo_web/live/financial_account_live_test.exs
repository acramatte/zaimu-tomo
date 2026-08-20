defmodule ZaimuTomoWeb.FinancialAccountLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.FinancialAccountsFixtures

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

  test "shows subtype and liquidity inputs only when account_type is investment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/accounts")

    # Simulate changing the account_type to savings and validate - fields should be absent
    html =
      view
      |> form("#financial-account-form", %{"account" => %{"account_type" => "savings"}})
      |> render_change()

    refute html =~ "id=\"account_subtype\""
    refute html =~ "id=\"account_liquidity\""

    # Simulate changing the account_type to investment and validate - fields should be present
    html =
      view
      |> form("#financial-account-form", %{"account" => %{"account_type" => "investment"}})
      |> render_change()

    assert html =~ "id=\"account_subtype\""
    assert html =~ "id=\"account_liquidity\""

    # Now submit a full investment account with subtype and liquidity
    view
    |> form("#financial-account-form", %{
      "account" => %{
        "name" => "Brokerage",
        "account_type" => "investment",
        "currency" => "usd",
        "subtype" => "retirement",
        "liquidity" => "restricted",
        "balance" => "500.00",
        "recorded_on" => "2026-07-28"
      }
    })
    |> render_submit()

    assert render(view) =~ "Brokerage"
    assert render(view) =~ "USD 500.00"
  end
end
