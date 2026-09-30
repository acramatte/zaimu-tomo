defmodule ZaimuTomo.DevSeeds do
  @moduledoc false

  alias ZaimuTomo.Accounts
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Repo

  @demo_email "demo@zaimutomo.test"
  @demo_password "demo-password-123"

  @accounts [
    %{
      name: "Daily spending",
      account_type: :cash,
      currency: "CHF",
      bank_name: "Zürcher Kantonalbank",
      account_number: "CH93 0070 0116 2014 6868 3",
      source: :bank_sync,
      amount_cents: 423_800
    },
    %{
      name: "Emergency fund",
      account_type: :savings,
      currency: "CHF",
      bank_name: "Zürcher Kantonalbank",
      account_number: "CH21 0070 0116 2014 6868 4",
      source: :bank_sync,
      amount_cents: 1_580_000
    },
    %{
      name: "Travel wallet",
      account_type: :cash,
      currency: "EUR",
      bank_name: "Cash",
      account_number: "EUR travel cash",
      source: :manual,
      amount_cents: 26_550
    },
    %{
      name: "Global index fund",
      account_type: :investment,
      currency: "USD",
      bank_name: "Interactive Brokers",
      account_number: "U1234567",
      source: :bank_sync,
      amount_cents: 4_275_000
    },
    %{
      name: "Pillar 3a",
      account_type: :investment,
      currency: "CHF",
      bank_name: "VIAC",
      account_number: "3a-004281",
      source: :bank_sync,
      amount_cents: 8_940_000
    }
  ]

  def seed! do
    user = ensure_demo_user!()
    scope = Scope.for_user(user)

    accounts = Enum.map(@accounts, &ensure_account!(scope, &1))

    %{user: user, accounts: accounts}
  end

  def demo_credentials, do: %{email: @demo_email, password: @demo_password}

  defp ensure_demo_user! do
    case Accounts.get_user_by_email(@demo_email) do
      nil ->
        {:ok, user} = Accounts.register_user(%{email: @demo_email})

        {:ok, user} =
          Accounts.update_user_profile(user, %{display_name: "Maya Keller", base_currency: "CHF"})

        {:ok, {user, _expired_tokens}} =
          Accounts.update_user_password(user, %{password: @demo_password})

        user

      user ->
        user
    end
  end

  defp ensure_account!(scope, attrs) do
    case Repo.get_by(FinancialAccount, user_id: scope.user.id, name: attrs.name) do
      nil ->
        {:ok, account_with_balance} =
          FinancialAccounts.create_financial_account_with_balance(
            scope,
            Map.take(attrs, [
              :name,
              :account_type,
              :currency,
              :bank_name,
              :account_number,
              :source
            ]),
            %{amount_cents: attrs.amount_cents, recorded_on: Date.utc_today()}
          )

        account_with_balance

      account ->
        %{
          account: account,
          balance_snapshot: ensure_balance_snapshot!(scope, account, attrs.amount_cents)
        }
    end
  end

  defp ensure_balance_snapshot!(scope, account, amount_cents) do
    case FinancialAccounts.list_balance_snapshots(scope, account) do
      [snapshot | _] ->
        snapshot

      [] ->
        {:ok, snapshot} =
          FinancialAccounts.record_balance(scope, account, %{
            amount_cents: amount_cents,
            recorded_on: Date.utc_today()
          })

        snapshot
    end
  end
end
