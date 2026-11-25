defmodule ZaimuTomo.Statements.ReconciliationTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Statements.{Matcher, Reconciliation, Statement, StatementLine}

  defp line(id, amount_cents, description \\ "Line") do
    %StatementLine{
      id: id,
      position: id,
      booking_date: ~D[2026-10-03],
      description: description,
      amount_cents: amount_cents,
      currency: "CHF"
    }
  end

  defp entry(id, cents) do
    %JournalEntry{
      id: id,
      amount_cents: cents,
      currency: "CHF",
      date: ~D[2026-10-01],
      issuer: "ACME"
    }
  end

  describe "new/4 invariants" do
    test "raises FunctionClauseError when statement lines are not preloaded" do
      statement = List.first([%Statement{id: 1, lines: %Ecto.Association.NotLoaded{}}])

      assert_raise FunctionClauseError, fn ->
        Reconciliation.new(statement, :ready, :balanced, %{})
      end
    end

    test "raises ArgumentError if a credit or zero-amount line is matched" do
      credit = line(1, 5_000, "Refund")
      statement = %Statement{id: 1, lines: [credit]}

      assert_raise ArgumentError, ~r/non-debit/, fn ->
        Reconciliation.new(statement, :ready, :balanced, %{1 => {entry(10, 5_000), :named}})
      end

      zero = line(2, 0, "Zero")
      statement = %Statement{id: 1, lines: [zero]}

      assert_raise ArgumentError, ~r/non-debit/, fn ->
        Reconciliation.new(statement, :ready, :balanced, %{2 => {entry(10, 0), :amount_only}})
      end
    end

    test "raises FunctionClauseError for an unknown confidence level" do
      debit = line(1, -5_000, "ACME")
      statement = %Statement{id: 1, lines: [debit]}

      assert_raise FunctionClauseError, fn ->
        Reconciliation.new(statement, :ready, :balanced, %{1 => {entry(10, 5_000), :guessed}})
      end
    end

    test "summary and row partition invariants hold across all filters" do
      lines = [
        line(1, -4_200, "Named"),
        line(2, -1_500, "Amount only"),
        line(3, -700, "Unbacked"),
        line(4, 10_000, "Credit")
      ]

      statement = %Statement{id: 1, lines: lines}

      matches = %{
        1 => {entry(10, 4_200), :named},
        2 => {entry(11, 1_500), :amount_only}
      }

      reconciliation = Reconciliation.new(statement, :ready, :balanced, matches)

      assert reconciliation.summary == %{debits: 3, debits_backed: 2, credits: 1}

      assert reconciliation.summary.debits + reconciliation.summary.credits ==
               length(reconciliation.rows)

      assert reconciliation.summary.debits_backed <= reconciliation.summary.debits

      all = Reconciliation.rows(reconciliation, :all)
      backed = Reconciliation.rows(reconciliation, :backed)
      unbacked = Reconciliation.rows(reconciliation, :unbacked)
      credits = Reconciliation.rows(reconciliation, :credits)

      assert length(all) == length(backed) + length(unbacked) + length(credits)
      assert Enum.map(backed, & &1.line.id) == [1, 2]
      assert Enum.map(unbacked, &{&1.line.id, &1.backing}) == [{3, :unbacked}]
      assert Enum.map(credits, &{&1.line.id, &1.backing}) == [{4, :credit}]
    end
  end

  describe "filters/0 and rows/2" do
    test "every exported filter works and unknown filters raise FunctionClauseError" do
      statement = %Statement{id: 1, lines: [line(1, -1_000)]}
      reconciliation = Reconciliation.new(statement, :ready, :balanced, %{})

      filters = Reconciliation.filters()
      assert Enum.any?(filters)
      assert MapSet.new(filters) == MapSet.new([:all, :unbacked, :backed, :credits])

      for filter <- filters do
        assert is_list(Reconciliation.rows(reconciliation, filter))
      end

      for bad_filter <- [:invalid, :debits, "backed", nil] do
        assert_raise FunctionClauseError, fn ->
          Reconciliation.rows(reconciliation, bad_filter)
        end
      end
    end

    test "Matcher.confidences/0 matches the known confidence levels" do
      assert Matcher.confidences() == [:named, :amount_only]
    end
  end
end
