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
      balance_history: [
        {6, 356_200},
        {4, 389_600},
        {3, 405_100},
        {1, 391_200},
        {0, 423_800}
      ]
    },
    %{
      name: "Emergency fund",
      account_type: :savings,
      currency: "CHF",
      bank_name: "Zürcher Kantonalbank",
      account_number: "CH21 0070 0116 2014 6868 4",
      source: :bank_sync,
      balance_history: [
        {6, 1_420_000},
        {4, 1_460_000},
        {3, 1_495_000},
        {1, 1_535_000},
        {0, 1_580_000}
      ]
    },
    %{
      name: "Travel wallet",
      account_type: :cash,
      currency: "EUR",
      bank_name: "Cash",
      account_number: "EUR travel cash",
      source: :manual,
      balance_history: [
        {6, 18_900},
        {4, 35_200},
        {3, 41_800},
        {1, 30_400},
        {0, 26_550}
      ]
    },
    %{
      name: "Global index fund",
      account_type: :investment,
      currency: "USD",
      bank_name: "Interactive Brokers",
      account_number: "U1234567",
      source: :bank_sync,
      balance_history: [
        {6, 3_930_000},
        {4, 4_080_000},
        {3, 4_160_000},
        {1, 4_230_000},
        {0, 4_275_000}
      ]
    },
    %{
      name: "Pillar 3a",
      account_type: :investment,
      currency: "CHF",
      bank_name: "VIAC",
      account_number: "3a-004281",
      source: :bank_sync,
      balance_history: [
        {6, 8_300_000},
        {4, 8_510_000},
        {3, 8_650_000},
        {1, 8_780_000},
        {0, 8_940_000}
      ]
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
    balance_history = balance_history(attrs, Date.utc_today())

    account =
      case Repo.get_by(FinancialAccount, user_id: scope.user.id, name: attrs.name) do
        nil ->
          [initial_snapshot | _] = balance_history

          {:ok, %{account: account}} =
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
              initial_snapshot
            )

          account

        account ->
          account
      end

    ensure_balance_history!(scope, account, balance_history)

    %{
      account: account,
      balance_snapshot: scope |> FinancialAccounts.list_balance_snapshots(account) |> hd()
    }
  end

  defp balance_history(attrs, today) do
    Enum.map(attrs.balance_history, fn {months_ago, amount_cents} ->
      %{amount_cents: amount_cents, recorded_on: Date.shift(today, month: -months_ago)}
    end)
  end

  defp ensure_balance_history!(scope, account, balance_history) do
    recorded_on_dates =
      scope
      |> FinancialAccounts.list_balance_snapshots(account)
      |> MapSet.new(& &1.recorded_on)

    Enum.each(balance_history, fn snapshot ->
      unless MapSet.member?(recorded_on_dates, snapshot.recorded_on) do
        {:ok, _snapshot} = FinancialAccounts.record_balance(scope, account, snapshot)
      end
    end)
  end
end
