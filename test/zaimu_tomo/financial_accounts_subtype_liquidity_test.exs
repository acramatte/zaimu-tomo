defmodule ZaimuTomo.FinancialAccounts.SubtypeLiquidityTest do
  use ZaimuTomo.DataCase

  alias ZaimuTomo.FinancialAccounts

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]

  test "investment account round-trip keeps optional subtype and liquidity as nil when omitted" do
    scope = user_scope_fixture()

    {:ok, %{account: account}} =
      FinancialAccounts.create_financial_account_with_balance(
        scope,
        %{name: "Brokerage", account_type: :investment, currency: "USD"},
        %{amount_cents: 1_000, recorded_on: ~D[2026-07-28]}
      )

    assert account.account_type == :investment
    assert account.subtype == nil
    assert account.liquidity == nil
  end

  test "accepts every valid liquidity value for investment accounts" do
    scope = user_scope_fixture()

    for liquidity <- [:liquid, :restricted, :illiquid] do
      {:ok, %{account: account}} =
        FinancialAccounts.create_financial_account_with_balance(
          scope,
          %{name: "Brokerage-#{liquidity}", account_type: :investment, currency: "USD", liquidity: liquidity},
          %{amount_cents: 1_000, recorded_on: ~D[2026-07-28]}
        )

      assert account.liquidity == liquidity
    end
  end

  test "rejects invalid liquidity values" do
    scope = user_scope_fixture()

    assert {:error, changeset} =
             FinancialAccounts.create_financial_account_with_balance(
               scope,
               %{name: "Brokerage", account_type: :investment, currency: "USD", liquidity: :fast},
               %{amount_cents: 1_000, recorded_on: ~D[2026-07-28]}
             )

    assert {_msg, _meta} = changeset.errors[:liquidity]
  end

  test "backward compatibility: existing fixtures without fields still work and have nil values" do
    scope = user_scope_fixture()

    account =
      ZaimuTomo.FinancialAccounts.create_financial_account_with_balance(
        scope,
        %{name: "LegacySavings", account_type: :savings, currency: "EUR"},
        %{amount_cents: 10_000, recorded_on: ~D[2026-07-28]}
      )

    # account may be {:ok, %{account: account}} or other, normalize
    case account do
      {:ok, %{account: account}} ->
        assert account.subtype == nil
        assert account.liquidity == nil

      other ->
        flunk("unexpected result: #{inspect(other)}")
    end
  end
end
