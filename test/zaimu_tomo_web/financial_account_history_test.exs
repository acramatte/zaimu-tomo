defmodule ZaimuTomoWeb.FinancialAccountHistoryTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.FinancialAccounts.{BalanceSnapshot, FinancialAccount}
  alias ZaimuTomoWeb.FinancialAccountHistory

  describe "first_month/1 and period_label/1" do
    test "returns the twelve inclusive months ending at the reference month" do
      assert FinancialAccountHistory.first_month(~D[2026-09-30]) == ~D[2025-10-01]
      assert FinancialAccountHistory.period_label(~D[2026-09-30]) == "Oct 2025 – Sep 2026"
    end
  end

  describe "series/3" do
    test "uses the latest snapshot in each month and leaves missing months empty" do
      account = %FinancialAccount{id: 1, name: "Everyday", currency: "EUR"}

      snapshots = [
        snapshot(1, 1, ~D[2025-09-30], 1_000),
        snapshot(2, 1, ~D[2025-10-08], 2_000),
        snapshot(3, 1, ~D[2025-10-31], 3_000),
        snapshot(4, 1, ~D[2025-10-31], 4_000),
        snapshot(5, 1, ~D[2026-09-30], 9_000),
        snapshot(6, 1, ~D[2026-10-01], 10_000)
      ]

      assert [series] = FinancialAccountHistory.series([account], snapshots, ~D[2026-09-30])
      assert series.account_id == account.id
      assert series.currency == "EUR"
      assert length(series.points) == 12

      assert Enum.map(series.points, & &1.label) ==
               [
                 "Oct",
                 "Nov",
                 "Dec",
                 "Jan",
                 "Feb",
                 "Mar",
                 "Apr",
                 "May",
                 "Jun",
                 "Jul",
                 "Aug",
                 "Sep"
               ]

      assert Enum.at(series.points, 0) == %{
               label: "Oct",
               full_label: "October 2025",
               value: 4_000,
               recorded_on: ~D[2025-10-31]
             }

      assert Enum.at(series.points, 1).value == nil
      assert Enum.at(series.points, 11).value == 9_000
    end

    test "keeps each account's currency and assigns distinct colors in stable name order" do
      accounts = [
        %FinancialAccount{id: 2, name: "Travel", currency: "USD"},
        %FinancialAccount{id: 1, name: "Everyday", currency: "EUR"}
      ]

      assert [everyday, travel] = FinancialAccountHistory.series(accounts, [], ~D[2026-09-30])
      assert everyday.name == "Everyday"
      assert everyday.currency == "EUR"
      assert travel.name == "Travel"
      assert travel.currency == "USD"
      refute everyday.color == travel.color
      assert Enum.all?(everyday.points, &is_nil(&1.value))
    end
  end

  describe "total_series/3" do
    test "carries prior balances and waits until every account has a known balance" do
      accounts = [
        %FinancialAccount{id: 1, name: "Everyday", currency: "EUR"},
        %FinancialAccount{id: 2, name: "Savings", currency: "EUR"},
        %FinancialAccount{id: 3, name: "Dollar", currency: "USD"}
      ]

      snapshots = [
        snapshot(1, 1, ~D[2025-08-01], 500),
        snapshot(2, 1, ~D[2025-09-30], 1_000),
        snapshot(3, 2, ~D[2025-12-10], 2_000),
        snapshot(4, 1, ~D[2026-02-01], 1_500),
        snapshot(5, 3, ~D[2025-09-01], -500),
        snapshot(6, 3, ~D[2026-09-25], 0),
        snapshot(7, 1, ~D[2026-09-30], 99_999),
        snapshot(8, 99, ~D[2025-10-01], 99_999)
      ]

      assert [eur, usd] =
               FinancialAccountHistory.total_series(
                 accounts,
                 Enum.reverse(snapshots),
                 ~D[2026-09-20]
               )

      assert eur.kind == :total
      assert eur.account_id == "total-EUR"
      assert eur.currency == "EUR"
      assert length(eur.points) == 12
      assert Enum.map(Enum.take(eur.points, 5), & &1.value) == [nil, nil, 3_000, 3_000, 3_500]
      assert List.last(eur.points).value == 3_500
      assert List.last(eur.points).recorded_on == ~D[2026-09-20]
      assert Enum.at(eur.points, 2).recorded_on == ~D[2025-12-31]
      assert Enum.all?(usd.points, &(&1.value == -500))

      [_, updated_usd] = FinancialAccountHistory.total_series(accounts, snapshots, ~D[2026-09-30])
      assert List.last(updated_usd.points).value == 0
    end

    test "does not turn an account with no snapshots into a zero balance" do
      accounts = [
        %FinancialAccount{id: 1, name: "Known", currency: "CHF"},
        %FinancialAccount{id: 2, name: "Unknown", currency: "CHF"}
      ]

      [total] =
        FinancialAccountHistory.total_series(
          accounts,
          [snapshot(1, 1, ~D[2025-09-01], 0)],
          ~D[2026-09-30]
        )

      assert Enum.all?(total.points, &is_nil(&1.value))
      assert FinancialAccountHistory.total_series([], [], ~D[2026-09-30]) == []
    end

    test "uses chronological insertion time before ID for same-day corrections" do
      account = %FinancialAccount{id: 1, name: "Savings", currency: "EUR"}
      earlier = %{snapshot(2, 1, ~D[2026-09-01], 1_000) | inserted_at: ~U[2026-12-31 23:59:59Z]}
      later = %{snapshot(1, 1, ~D[2026-09-01], 2_000) | inserted_at: ~U[2027-01-01 00:00:00Z]}

      [individual] = FinancialAccountHistory.series([account], [earlier, later], ~D[2026-09-30])
      [total] = FinancialAccountHistory.total_series([account], [earlier, later], ~D[2026-09-30])
      assert List.last(individual.points).value == 2_000
      assert List.last(total.points).value == 2_000

      tied = %{later | id: 3, amount_cents: 3_000}
      [total] = FinancialAccountHistory.total_series([account], [tied, later], ~D[2026-09-30])
      assert List.last(total.points).value == 3_000
    end
  end

  defp snapshot(id, account_id, recorded_on, amount_cents) do
    %BalanceSnapshot{
      id: id,
      financial_account_id: account_id,
      recorded_on: recorded_on,
      amount_cents: amount_cents,
      inserted_at: DateTime.new!(recorded_on, ~T[00:00:00]) |> DateTime.add(id)
    }
  end
end
