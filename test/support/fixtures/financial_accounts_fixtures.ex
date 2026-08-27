defmodule ZaimuTomo.FinancialAccountsFixtures do
  def financial_account_fixture(scope, attrs \\ %{}) do
    account_attrs =
      attrs
      |> Map.take([:name, :account_type, :currency, :bank_name, :account_number, :subtype, :liquidity])
      |> Enum.into(%{name: "Savings", account_type: :savings, currency: "EUR"})

    balance_attrs =
      attrs
      |> Map.take([:amount_cents, :recorded_on])
      |> Enum.into(%{amount_cents: 12_345, recorded_on: ~D[2026-07-28]})

    {:ok, %{account: account}} =
      ZaimuTomo.FinancialAccounts.create_financial_account_with_balance(
        scope,
        account_attrs,
        balance_attrs
      )

    account
  end

  def balance_snapshot_fixture(scope, account, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{amount_cents: 12_345, recorded_on: ~D[2026-07-28]})
    {:ok, snapshot} = ZaimuTomo.FinancialAccounts.record_balance(scope, account, attrs)
    snapshot
  end
end
