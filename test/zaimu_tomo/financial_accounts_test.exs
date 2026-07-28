defmodule ZaimuTomo.FinancialAccountsTest do
  use ZaimuTomo.DataCase

  alias ZaimuTomo.FinancialAccounts

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures

  test "creates a scoped financial account with its initial balance atomically" do
    scope = user_scope_fixture()

    assert {:ok, %{account: account, balance_snapshot: snapshot}} =
             FinancialAccounts.create_financial_account_with_balance(
               scope,
               %{
                 name: "Rainy day",
                 account_type: :savings,
                 currency: "eur",
                 bank_name: "Raiffeisen",
                 account_number: "example-account-1234"
               },
               %{amount_cents: 12_345, recorded_on: ~D[2026-07-28]}
             )

    assert account.user_id == scope.user.id
    assert account.currency == "EUR"
    assert account.bank_name == "Raiffeisen"
    assert account.account_number == "example-account-1234"
    assert snapshot.financial_account_id == account.id
    assert snapshot.amount_cents == 12_345
  end

  test "does not create an account when its initial balance is invalid" do
    scope = user_scope_fixture()

    assert {:error, changeset} =
             FinancialAccounts.create_financial_account_with_balance(
               scope,
               %{name: "Rainy day", account_type: :savings, currency: "EUR"},
               %{amount_cents: nil, recorded_on: ~D[2026-07-28]}
             )

    assert {"can't be blank", _} = changeset.errors[:amount_cents]
    assert FinancialAccounts.list_financial_accounts(scope) == []
  end

  test "returns each account's latest balance without leaking another user's accounts" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    account = financial_account_fixture(scope, %{name: "Savings", amount_cents: 10_000})
    financial_account_fixture(other_scope, %{name: "Private", amount_cents: 99_999})

    balance_snapshot_fixture(scope, account, %{amount_cents: 12_345, recorded_on: ~D[2026-07-29]})

    assert [%{account: returned_account, balance_snapshot: snapshot}] =
             FinancialAccounts.list_financial_accounts_with_latest_balance(scope)

    assert returned_account.id == account.id
    assert snapshot.amount_cents == 12_345
    assert snapshot.recorded_on == ~D[2026-07-29]
  end

  test "lists only savings accounts for the dashboard" do
    scope = user_scope_fixture()
    financial_account_fixture(scope, %{name: "Savings", account_type: :savings})

    financial_account_fixture(scope, %{
      name: "Brokerage",
      account_type: :investment,
      currency: "USD"
    })

    assert [%{account: %{name: "Savings", account_type: :savings}}] =
             FinancialAccounts.list_savings_accounts_with_latest_balance(scope)
  end

  test "lists only cash accounts for the dashboard" do
    scope = user_scope_fixture()
    financial_account_fixture(scope, %{name: "Wallet", account_type: :cash, currency: "CHF"})
    financial_account_fixture(scope, %{name: "Savings", account_type: :savings})

    assert [%{account: %{name: "Wallet", account_type: :cash}}] =
             FinancialAccounts.list_cash_accounts_with_latest_balance(scope)
  end

  test "lists only investment accounts for the dashboard" do
    scope = user_scope_fixture()

    financial_account_fixture(scope, %{
      name: "Brokerage",
      account_type: :investment,
      currency: "USD"
    })

    financial_account_fixture(scope, %{name: "Wallet", account_type: :cash})

    assert [%{account: %{name: "Brokerage", account_type: :investment}}] =
             FinancialAccounts.list_investment_accounts_with_latest_balance(scope)
  end

  test "records balance snapshots only for the account owner" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    account = financial_account_fixture(scope)

    assert_raise MatchError, fn ->
      FinancialAccounts.record_balance(other_scope, account, %{
        amount_cents: 1,
        recorded_on: ~D[2026-07-29]
      })
    end
  end
end
