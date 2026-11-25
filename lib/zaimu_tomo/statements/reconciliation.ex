defmodule ZaimuTomo.Statements.Reconciliation do
  @moduledoc """
  One statement checked against the journal: every line with the posted
  journal entry that backs it, if any.

  Built by `ZaimuTomo.Statements.reconcile/2` on every read and never stored,
  so an invoice posted after the upload backs its line on the next read.
  A debit line is `{:matched, entry, confidence}` or `:unbacked`. A credit is
  `:credit` and is never matched, because only money out is backed by an
  invoice.
  """

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{Matcher, Statement, StatementLine}

  @type backing :: {:matched, JournalEntry.t(), Matcher.confidence()} | :unbacked | :credit
  @type row :: %{line: StatementLine.t(), backing: backing()}
  @type filter :: :all | :backed | :unbacked | :credits
  @type summary :: %{
          debits: non_neg_integer(),
          debits_backed: non_neg_integer(),
          credits: non_neg_integer()
        }

  @enforce_keys [:statement, :status, :balance, :rows, :summary]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          statement: Statement.t(),
          status: Statements.status(),
          balance: Statements.balance() | nil,
          rows: [row()],
          summary: summary()
        }

  @filters [:all, :unbacked, :backed, :credits]
  @confidences Matcher.confidences()

  @doc "All supported reconciliation row filters."
  @spec filters() :: [filter()]
  def filters, do: @filters

  @doc false
  @spec new(
          Statement.t(),
          Statements.status(),
          Statements.balance() | nil,
          %{integer() => {JournalEntry.t(), Matcher.confidence()}}
        ) :: t()
  def new(%Statement{lines: lines} = statement, status, balance, matches) when is_list(lines) do
    rows = Enum.map(lines, &%{line: &1, backing: backing(&1, Map.get(matches, &1.id))})

    %__MODULE__{
      statement: statement,
      status: status,
      balance: balance,
      rows: rows,
      summary: summarize(rows)
    }
  end

  defp backing(%{amount_cents: cents, id: id}, {_entry, _confidence}) when cents >= 0 do
    raise ArgumentError, "non-debit statement line #{inspect(id)} cannot be matched"
  end

  defp backing(%{amount_cents: cents}, nil) when cents > 0, do: :credit
  defp backing(_line, nil), do: :unbacked

  defp backing(_line, {entry, confidence}) when confidence in @confidences,
    do: {:matched, entry, confidence}

  @doc """
  The rows under one filter, in statement order: `:backed` and `:unbacked`
  hold debits only, `:credits` holds money in.
  """
  @spec rows(t(), filter()) :: [row()]
  def rows(%__MODULE__{rows: rows}, :all), do: rows

  def rows(%__MODULE__{rows: rows}, filter) when filter in @filters,
    do: Enum.filter(rows, &(section(&1) == filter))

  defp section(%{backing: :credit}), do: :credits
  defp section(%{backing: :unbacked}), do: :unbacked
  defp section(%{backing: {:matched, _entry, _confidence}}), do: :backed

  defp summarize(rows) do
    counts = Enum.frequencies_by(rows, &section/1)
    backed = Map.get(counts, :backed, 0)

    %{
      debits: backed + Map.get(counts, :unbacked, 0),
      debits_backed: backed,
      credits: Map.get(counts, :credits, 0)
    }
  end
end
