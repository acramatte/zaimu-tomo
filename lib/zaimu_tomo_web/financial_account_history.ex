defmodule ZaimuTomoWeb.FinancialAccountHistory do
  @moduledoc """
  Builds the twelve-month monthly balance series used by financial-account charts.

  A month uses its latest recorded snapshot. Individual series retain empty
  months; the chart connects their observed points across those gaps. Currency
  totals carry each account's latest known balance forward and remain unknown
  until every account in that currency has a recorded balance.
  """

  alias ZaimuTomoWeb.Spending

  @months_per_year 12
  @series_colors [
    "oklch(0.55 0.08 240)",
    "oklch(0.55 0.10 145)",
    "oklch(0.55 0.13 35)",
    "oklch(0.55 0.13 320)",
    "oklch(0.55 0.10 200)",
    "oklch(0.55 0.07 75)",
    "oklch(0.55 0.10 15)",
    "oklch(0.55 0.10 280)"
  ]

  @doc "Returns the first day of the twelve-month period ending in `reference_date`."
  def first_month(%Date{} = reference_date) do
    reference_date
    |> Spending.month_starts(@months_per_year)
    |> List.first()
  end

  @doc "Formats the inclusive month range used by an account balance chart."
  def period_label(%Date{} = reference_date) do
    start_label = Calendar.strftime(first_month(reference_date), "%b %Y")
    end_label = Calendar.strftime(reference_date, "%b %Y")
    "#{start_label} – #{end_label}"
  end

  @doc "Builds one monthly balance series per account, oldest month first."
  def series(accounts, snapshots, %Date{} = reference_date)
      when is_list(accounts) and is_list(snapshots) do
    month_starts = Spending.month_starts(reference_date, @months_per_year)
    start_date = List.first(month_starts)

    latest_by_account_month =
      snapshots
      |> Enum.filter(fn snapshot ->
        Date.compare(snapshot.recorded_on, start_date) != :lt and
          Date.compare(snapshot.recorded_on, reference_date) != :gt
      end)
      |> Enum.group_by(fn snapshot ->
        {snapshot.financial_account_id, Date.beginning_of_month(snapshot.recorded_on)}
      end)
      |> Map.new(fn {key, month_snapshots} ->
        {key, Enum.max_by(month_snapshots, &snapshot_order/1)}
      end)

    accounts
    |> Enum.sort_by(&{&1.name, &1.id})
    |> Enum.with_index()
    |> Enum.map(fn {account, index} ->
      points =
        Enum.map(month_starts, fn month_start ->
          snapshot = Map.get(latest_by_account_month, {account.id, month_start})

          %{
            label: Calendar.strftime(month_start, "%b"),
            full_label: Calendar.strftime(month_start, "%B %Y"),
            value: snapshot && snapshot.amount_cents,
            recorded_on: snapshot && snapshot.recorded_on
          }
        end)

      %{
        account_id: account.id,
        name: account.name,
        currency: account.currency,
        color: Enum.at(@series_colors, rem(index, length(@series_colors))),
        points: points
      }
    end)
  end

  @doc "Builds currency totals from latest-known balances, including pre-window snapshots."
  def total_series(accounts, snapshots, %Date{} = reference_date) do
    month_starts = Spending.month_starts(reference_date, @months_per_year)
    first_month = List.first(month_starts)

    {baseline, history} =
      snapshots
      |> Enum.filter(&(Date.compare(&1.recorded_on, reference_date) != :gt))
      |> Enum.sort_by(&snapshot_order/1)
      |> Enum.split_with(&(Date.compare(&1.recorded_on, first_month) == :lt))

    baseline_by_account = Map.new(baseline, &{&1.financial_account_id, &1})
    history_by_month = Enum.group_by(history, &Date.beginning_of_month(&1.recorded_on))

    {monthly_balances, _latest} =
      Enum.map_reduce(month_starts, baseline_by_account, fn month_start, latest ->
        updated =
          history_by_month
          |> Map.get(month_start, [])
          |> Enum.reduce(latest, &Map.put(&2, &1.financial_account_id, &1))

        cutoff = Enum.min([Date.end_of_month(month_start), reference_date], Date)
        {%{month_start: month_start, cutoff: cutoff, balances: updated}, updated}
      end)

    accounts
    |> Enum.group_by(& &1.currency)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {currency, currency_accounts} ->
      %{
        account_id: "total-#{currency}",
        name: "Total wealth",
        currency: currency,
        color: "var(--ink)",
        kind: :total,
        points: Enum.map(monthly_balances, &total_point(&1, currency_accounts))
      }
    end)
  end

  defp total_point(month, accounts) do
    snapshots = Enum.map(accounts, &Map.get(month.balances, &1.id))

    value =
      if Enum.all?(snapshots, &(not is_nil(&1))) do
        Enum.sum_by(snapshots, & &1.amount_cents)
      end

    %{
      label: Calendar.strftime(month.month_start, "%b"),
      full_label: Calendar.strftime(month.month_start, "%B %Y"),
      value: value,
      recorded_on: if(is_integer(value), do: month.cutoff)
    }
  end

  defp snapshot_order(snapshot) do
    {Date.to_gregorian_days(snapshot.recorded_on), DateTime.to_unix(snapshot.inserted_at),
     snapshot.id}
  end
end
