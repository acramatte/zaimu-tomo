defmodule ZaimuTomo.RecurringExpenses.RecurringExpenseTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.RecurringExpenses.RecurringExpense

  defp expense(overrides \\ %{}) do
    struct!(
      RecurringExpense,
      Map.merge(
        %{
          name: "Rent",
          amount_cents: 118_000,
          currency: "EUR",
          frequency: :monthly,
          start_date: ~D[2026-01-15],
          end_date: nil
        },
        Map.new(overrides)
      )
    )
  end

  test "monthly occurrences follow the start day each month" do
    assert RecurringExpense.occurrences(expense(), ~D[2026-01-01], ~D[2026-03-31]) ==
             [~D[2026-01-15], ~D[2026-02-15], ~D[2026-03-15]]
  end

  test "the first occurrence is the start date itself" do
    assert RecurringExpense.occurrences(expense(), ~D[2026-01-01], ~D[2026-01-31]) ==
             [~D[2026-01-15]]
  end

  test "no occurrence before the start date" do
    assert RecurringExpense.occurrences(expense(), ~D[2025-12-01], ~D[2025-12-31]) == []
  end

  test "monthly occurrences clamp to the last day of shorter months" do
    jan_31 = expense(start_date: ~D[2026-01-31])

    assert RecurringExpense.occurrences(jan_31, ~D[2026-01-01], ~D[2026-04-30]) ==
             [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30]]
  end

  test "quarterly occurrences land every three months" do
    quarterly = expense(frequency: :quarterly, start_date: ~D[2026-01-15])

    assert RecurringExpense.occurrences(quarterly, ~D[2026-01-01], ~D[2026-10-31]) ==
             [~D[2026-01-15], ~D[2026-04-15], ~D[2026-07-15], ~D[2026-10-15]]
  end

  test "yearly occurrences land on the start month and day" do
    yearly = expense(frequency: :yearly, start_date: ~D[2025-06-20])

    assert RecurringExpense.occurrences(yearly, ~D[2025-01-01], ~D[2027-12-31]) ==
             [~D[2025-06-20], ~D[2026-06-20], ~D[2027-06-20]]
  end

  test "a Feb-29 yearly anchor falls back to Feb 28 outside leap years and back to Feb 29 in leap years" do
    leap_start = expense(frequency: :yearly, start_date: ~D[2024-02-29])

    assert RecurringExpense.occurrences(leap_start, ~D[2025-01-01], ~D[2027-12-31]) ==
             [~D[2025-02-28], ~D[2026-02-28], ~D[2027-02-28]]

    assert RecurringExpense.occurrences(leap_start, ~D[2028-01-01], ~D[2028-12-31]) ==
             [~D[2028-02-29]]
  end

  test "the end date is inclusive and stops later occurrences" do
    ended = expense(end_date: ~D[2026-03-10])

    assert RecurringExpense.occurrences(ended, ~D[2026-01-01], ~D[2026-04-30]) ==
             [~D[2026-01-15], ~D[2026-02-15]]
  end

  test "next_occurrence returns the first occurrence on or after the reference" do
    assert RecurringExpense.next_occurrence(expense(), ~D[2026-02-20]) == ~D[2026-03-15]
    assert RecurringExpense.next_occurrence(expense(), ~D[2026-03-15]) == ~D[2026-03-15]
  end

  test "next_occurrence is nil once the expense has ended" do
    ended = expense(end_date: ~D[2026-03-10])

    assert RecurringExpense.next_occurrence(ended, ~D[2026-04-01]) == nil
  end
end
