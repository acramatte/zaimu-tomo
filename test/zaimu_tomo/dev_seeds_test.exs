defmodule ZaimuTomo.DevSeedsTest do
  use ZaimuTomo.DataCase

  alias ZaimuTomo.{Accounts, DevSeeds, FinancialAccounts}

  test "creates a demo user with varied financial accounts and balances" do
    assert %{user: user, accounts: accounts} = DevSeeds.seed!()

    assert user.email == "demo@zaimutomo.test"
    assert user.display_name == "Maya Keller"
    assert user.base_currency == "CHF"
    assert Accounts.get_user_by_email_and_password(user.email, "demo-password-123")

    assert [
             {"Daily spending", :cash, "CHF", :bank_sync, 423_800},
             {"Emergency fund", :savings, "CHF", :bank_sync, 1_580_000},
             {"Travel wallet", :cash, "EUR", :manual, 26_550},
             {"Global index fund", :investment, "USD", :bank_sync, 4_275_000},
             {"Pillar 3a", :investment, "CHF", :bank_sync, 8_940_000}
           ] =
             accounts
             |> Enum.map(fn %{account: account, balance_snapshot: snapshot} ->
               {
                 account.name,
                 account.account_type,
                 account.currency,
                 account.source,
                 snapshot.amount_cents
               }
             end)

    scope = ZaimuTomo.Accounts.Scope.for_user(user)

    assert 5 == length(FinancialAccounts.list_financial_accounts(scope))
  end

  test "does not duplicate the demo user, accounts, or balances when run again" do
    first_seed = DevSeeds.seed!()
    second_seed = DevSeeds.seed!()

    assert first_seed.user.id == second_seed.user.id

    assert Enum.map(second_seed.accounts, & &1.account.id) ==
             Enum.map(first_seed.accounts, & &1.account.id)

    scope = ZaimuTomo.Accounts.Scope.for_user(second_seed.user)

    assert 5 == length(FinancialAccounts.list_financial_accounts(scope))

    assert Enum.all?(second_seed.accounts, fn %{account: account} ->
             length(FinancialAccounts.list_balance_snapshots(scope, account)) == 5
           end)
  end

  test "adds missing balance history to existing demo accounts" do
    %{user: user, accounts: accounts} = DevSeeds.seed!()
    scope = ZaimuTomo.Accounts.Scope.for_user(user)
    today = Date.utc_today()

    current_snapshot_ids =
      Map.new(accounts, fn %{account: account, balance_snapshot: snapshot} ->
        {account.id, snapshot.id}
      end)

    Enum.each(accounts, fn %{account: account} ->
      scope
      |> FinancialAccounts.list_balance_snapshots(account)
      |> Enum.reject(&(&1.recorded_on == today))
      |> Enum.each(&Repo.delete!/1)
    end)

    %{accounts: reseeded_accounts} = DevSeeds.seed!()

    assert Enum.all?(reseeded_accounts, fn %{account: account, balance_snapshot: snapshot} ->
             snapshot.id == Map.fetch!(current_snapshot_ids, account.id) and
               length(FinancialAccounts.list_balance_snapshots(scope, account)) == 5
           end)
  end

  test "creates monthly and bi-monthly balance history for every demo account" do
    %{user: user, accounts: accounts} = DevSeeds.seed!()
    scope = ZaimuTomo.Accounts.Scope.for_user(user)
    today = Date.utc_today()

    expected_dates = [
      today,
      Date.shift(today, month: -1),
      Date.shift(today, month: -3),
      Date.shift(today, month: -4),
      Date.shift(today, month: -6)
    ]

    assert Enum.all?(accounts, fn %{account: account, balance_snapshot: latest_snapshot} ->
             snapshots = FinancialAccounts.list_balance_snapshots(scope, account)

             latest_snapshot.id == hd(snapshots).id and
               Enum.map(snapshots, & &1.recorded_on) == expected_dates and
               length(snapshots) == length(expected_dates) and
               length(Enum.uniq_by(snapshots, & &1.amount_cents)) > 1
           end)
  end
end
