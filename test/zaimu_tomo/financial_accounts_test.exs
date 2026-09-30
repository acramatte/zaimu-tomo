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

  test "groups the latest account balances by their source currency for net worth" do
    scope = user_scope_fixture()
    eur_account = financial_account_fixture(scope, %{name: "Savings", amount_cents: 12_345})
    financial_account_fixture(scope, %{name: "Wallet", account_type: :cash, amount_cents: 10_000})

    financial_account_fixture(scope, %{
      name: "Brokerage",
      account_type: :investment,
      currency: "USD",
      amount_cents: 5_000
    })

    balance_snapshot_fixture(scope, eur_account, %{
      amount_cents: 20_000,
      recorded_on: ~D[2026-07-29]
    })

    assert [
             %{currency: "EUR", total_cents: 30_000, account_count: 2},
             %{currency: "USD", total_cents: 5_000, account_count: 1}
           ] = FinancialAccounts.list_net_worth_by_currency(scope)
  end

  test "lists dated balance history only for the current user" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()

    account =
      financial_account_fixture(scope, %{
        name: "Main",
        amount_cents: 1_000,
        recorded_on: ~D[2025-09-30]
      })

    inside_range =
      balance_snapshot_fixture(scope, account, %{amount_cents: 2_000, recorded_on: ~D[2025-10-01]})

    end_of_range =
      balance_snapshot_fixture(scope, account, %{amount_cents: 3_000, recorded_on: ~D[2026-09-30]})

    balance_snapshot_fixture(scope, account, %{amount_cents: 4_000, recorded_on: ~D[2026-10-01]})
    financial_account_fixture(other_scope, %{name: "Private", recorded_on: ~D[2026-05-01]})

    assert FinancialAccounts.list_balance_history(scope, ~D[2025-10-01], ~D[2026-09-30]) ==
             [inside_range, end_of_range]
  end

  test "history baseline selects only each owned account's latest pre-window snapshot" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    account = financial_account_fixture(scope, %{recorded_on: ~D[2025-08-01]})

    first =
      balance_snapshot_fixture(scope, account, %{recorded_on: ~D[2025-09-30], amount_cents: 1_000})

    latest =
      balance_snapshot_fixture(scope, account, %{recorded_on: ~D[2025-09-30], amount_cents: 2_000})

    balance_snapshot_fixture(scope, account, %{recorded_on: ~D[2025-10-01], amount_cents: 3_000})
    balance_snapshot_fixture(scope, account, %{recorded_on: ~D[2026-10-01], amount_cents: 4_000})
    financial_account_fixture(other_scope, %{recorded_on: ~D[2025-09-30]})
    financial_account_fixture(scope, %{recorded_on: ~D[2025-10-01]})

    # Sequence IDs must not override a later insertion timestamp on the same balance date.
    first
    |> Ecto.Changeset.change(inserted_at: ~U[2026-01-01 00:00:00Z])
    |> ZaimuTomo.Repo.update!()

    latest
    |> Ecto.Changeset.change(inserted_at: ~U[2025-12-31 23:59:59Z])
    |> ZaimuTomo.Repo.update!()

    assert [baseline] = FinancialAccounts.list_balance_history_baseline(scope, ~D[2025-10-01])
    assert baseline.id == first.id
    assert baseline.amount_cents == 1_000
    assert FinancialAccounts.list_balance_history_baseline(other_scope, ~D[2025-01-01]) == []
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
