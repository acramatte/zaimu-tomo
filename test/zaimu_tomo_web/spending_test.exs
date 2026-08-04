defmodule ZaimuTomoWeb.SpendingTest do
  use ExUnit.Case, async: true

  alias ZaimuTomoWeb.Spending

  describe "month_pct/2" do
    test "is zero when both months are zero" do
      assert Spending.month_pct(0, 0) == 0.0
    end

    test "is 100 when there was no previous spending" do
      assert Spending.month_pct(500, 0) == 100.0
    end

    test "caps at 100" do
      assert Spending.month_pct(1500, 1000) == 100.0
    end

    test "computes the ratio" do
      assert Spending.month_pct(500, 1000) == 50.0
    end
  end

  describe "month_comparison_class/2" do
    test "is over when current exceeds previous" do
      assert Spending.month_comparison_class(1200, 1000) == "over"
    end

    test "is warn above 85% of previous" do
      assert Spending.month_comparison_class(900, 1000) == "warn"
    end

    test "is empty at or below 85% of previous" do
      assert Spending.month_comparison_class(850, 1000) == ""
      assert Spending.month_comparison_class(800, 1000) == ""
      assert Spending.month_comparison_class(0, 0) == ""
    end
  end

  describe "merge_categories/2" do
    test "merges current and previous categories with deltas" do
      current = [
        %{category: "Groceries", total_cents: 500, entry_count: 2},
        %{category: "Transport", total_cents: 300, entry_count: 1}
      ]

      previous = [
        %{category: "Groceries", total_cents: 400, entry_count: 1},
        %{category: "Home", total_cents: 700, entry_count: 1}
      ]

      merged = Spending.merge_categories(current, previous)

      groceries = Enum.find(merged, &(&1.category == "Groceries"))
      assert groceries.total_cents == 500
      assert groceries.previous_total_cents == 400
      assert groceries.delta_cents == 100

      home = Enum.find(merged, &(&1.category == "Home"))
      assert home.total_cents == 0
      assert home.previous_total_cents == 700
      assert home.delta_cents == -700
    end

    test "sorts by current total descending and assigns colors" do
      current = [
        %{category: "A", total_cents: 100, entry_count: 1},
        %{category: "B", total_cents: 300, entry_count: 1},
        %{category: "C", total_cents: 200, entry_count: 1}
      ]

      merged = Spending.merge_categories(current, [])

      assert Enum.map(merged, & &1.category) == ["B", "C", "A"]

      colors = Enum.map(merged, & &1.color)
      assert length(Enum.uniq(colors)) == 3
    end
  end

  describe "display_categories/1" do
    test "keeps up to six categories" do
      categories =
        for index <- 1..6 do
          %{
            category: "Cat #{index}",
            total_cents: index,
            previous_total_cents: 0,
            delta_cents: index
          }
        end

      assert length(Spending.display_categories(categories)) == 6
    end

    test "buckets the rest into Other" do
      categories =
        for index <- 1..8 do
          %{
            category: "Cat #{index}",
            total_cents: index * 100,
            previous_total_cents: index * 50,
            delta_cents: index * 50
          }
        end

      displayed = Spending.display_categories(categories)

      assert length(displayed) == 6
      assert Enum.at(displayed, 5).category == "Other"
      assert Enum.at(displayed, 5).total_cents == 600 + 700 + 800
    end
  end

  describe "shift_month/2" do
    test "shifts across year boundaries" do
      assert Spending.shift_month(~D[2026-01-01], -1) == ~D[2025-12-01]
      assert Spending.shift_month(~D[2026-12-01], 1) == ~D[2027-01-01]
    end

    test "normalizes to the first of the month" do
      assert Spending.shift_month(~D[2026-05-15], 0) == ~D[2026-05-01]
    end
  end
end
