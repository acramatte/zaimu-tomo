defmodule ZaimuTomoWeb.Spending do
  @moduledoc """
  Presentation helpers shared by the dashboard and the spending history page:
  category merge/display, month-over-month comparison metrics, and the
  per-month history series used by the trend charts.

  The history series is built on top of `ZaimuTomo.Accounting.monthly_spending/2`
  so it always agrees with the dashboard's definition of a month's spending.
  """

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @category_colors [
    "oklch(0.55 0.08 240)",
    "oklch(0.55 0.10 145)",
    "oklch(0.55 0.13 35)",
    "oklch(0.55 0.13 320)",
    "oklch(0.55 0.10 200)",
    "oklch(0.55 0.07 75)",
    "oklch(0.55 0.10 15)",
    "oklch(0.55 0.10 280)"
  ]

  @doc """
  Returns the last `month_count` monthly spending summaries ending at the
  month containing `reference_date`, oldest first.

  Each entry mirrors the shape of `Accounting.monthly_spending/2`
  (minus the category breakdown), so callers can render totals and trends
  consistently with the dashboard.
  """
  def monthly_history(%Scope{} = scope, %Date{} = reference_date, month_count \\ 6) do
    end_month_start = Date.beginning_of_month(reference_date)

    for offset <- (month_count - 1)..0//-1 do
      month_start = shift_month(end_month_start, -offset)
      Accounting.monthly_spending(scope, month_start)
    end
  end

  @doc "Merges current and previous month categories into comparison rows."
  def merge_categories(categories, previous_categories) do
    current_by_category = Map.new(categories, &{&1.category, &1})

    previous_by_category =
      Map.new(previous_categories, fn category ->
        {category.category, category.total_cents}
      end)

    current_by_category
    |> Map.keys()
    |> Kernel.++(Map.keys(previous_by_category))
    |> Enum.uniq()
    |> Enum.map(fn category ->
      current_total_cents =
        current_by_category
        |> Map.get(category, %{total_cents: 0})
        |> Map.fetch!(:total_cents)

      previous_total_cents = Map.get(previous_by_category, category, 0)

      %{
        category: category,
        total_cents: current_total_cents,
        previous_total_cents: previous_total_cents,
        delta_cents: current_total_cents - previous_total_cents
      }
    end)
    |> Enum.sort_by(fn category ->
      {-category.total_cents, -category.previous_total_cents, category.category}
    end)
    |> Enum.with_index()
    |> Enum.map(fn {category, index} ->
      category
      |> Map.put(:color, Enum.at(@category_colors, rem(index, length(@category_colors))))
    end)
  end

  @doc "Buckets categories beyond the visible limit into a single Other row."
  def display_categories(categories) when length(categories) <= 6, do: categories

  def display_categories(categories) do
    {visible_categories, remaining_categories} = Enum.split(categories, 5)

    other = %{
      category: "Other",
      color: "oklch(0.55 0.02 60)",
      total_cents: Enum.sum_by(remaining_categories, & &1.total_cents),
      previous_total_cents: Enum.sum_by(remaining_categories, & &1.previous_total_cents),
      delta_cents: Enum.sum_by(remaining_categories, & &1.delta_cents)
    }

    visible_categories ++ [other]
  end

  @doc "Percentage of the previous month's total spent so far, capped at 100."
  def month_pct(0, 0), do: 0.0
  def month_pct(_current, 0), do: 100.0

  def month_pct(current, previous) do
    min(100.0, current / previous * 100)
  end

  @doc "Comparison state class for the spending progress bar."
  def month_comparison_class(current, previous) when previous > 0 and current > previous,
    do: "over"

  def month_comparison_class(current, previous) when previous > 0 and current > previous * 0.85,
    do: "warn"

  def month_comparison_class(_current, _previous), do: ""

  @doc "Shifts a month-start date by `delta` months (negative goes back in time)."
  def shift_month(%Date{year: year, month: month}, delta) do
    total = year * 12 + (month - 1) + delta
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end
end
