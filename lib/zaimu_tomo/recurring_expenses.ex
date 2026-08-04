defmodule ZaimuTomo.RecurringExpenses do
  @moduledoc """
  Recurring expenses (rent, subscriptions, memberships) and their
  reconciliation with journal entries created from uploaded invoices.

  Each recurring expense has a start date and an optional end date. The
  upcoming-occurrence helpers are pure functions on `RecurringExpense`; this
  context owns persistence, scoping, and the journal-entry link.
  """

  import Ecto.Query, warn: false

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.RecurringExpenses.RecurringExpense
  alias ZaimuTomo.Repo

  # How many upcoming occurrences the dashboard and the recurring page show.
  @upcoming_limit 5
  # Candidate-invoice window around an occurrence's due date.
  @candidate_window_days 14

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  def list_recurring_expenses(%Scope{user: user}) do
    from(e in RecurringExpense,
      where: e.user_id == ^user.id,
      order_by: [asc: e.name]
    )
    |> Repo.all()
  end

  def get_recurring_expense(%Scope{user: user}, id) do
    case Repo.get_by(RecurringExpense, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      expense -> {:ok, expense}
    end
  end

  def create_recurring_expense(%Scope{} = scope, attrs) do
    %RecurringExpense{}
    |> RecurringExpense.changeset(attrs, scope)
    |> Repo.insert()
  end

  def update_recurring_expense(%Scope{} = scope, %RecurringExpense{} = expense, attrs) do
    true = expense.user_id == scope.user.id

    expense
    |> RecurringExpense.changeset(attrs, scope)
    |> Repo.update()
  end

  def delete_recurring_expense(%Scope{} = scope, %RecurringExpense{} = expense) do
    true = expense.user_id == scope.user.id
    Repo.delete(expense)
  end

  def change_recurring_expense(%Scope{} = scope, %RecurringExpense{} = expense, attrs \\ %{}) do
    true = expense.user_id == scope.user.id
    RecurringExpense.changeset(expense, attrs, scope)
  end

  # ---------------------------------------------------------------------------
  # Upcoming occurrences
  # ---------------------------------------------------------------------------

  @doc """
  Returns the next `limit` occurrences across the user's active recurring
  expenses, ordered by date. Each item is `%{date: Date.t(), expense: ...}`.
  """
  def upcoming_occurrences(%Scope{} = scope, limit \\ @upcoming_limit) do
    today = Date.utc_today()

    scope
    |> list_recurring_expenses()
    |> Enum.flat_map(fn expense ->
      case RecurringExpense.next_occurrence(expense, today) do
        nil -> []
        date -> [{date, expense}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(limit)
    |> Enum.map(fn {date, expense} -> %{date: date, expense: expense} end)
  end

  @doc """
  Returns a `MapSet` of `{expense_id, {year, month}}` for every occurrence
  that already has a linked journal entry, so callers can mark occurrences as
  covered with a single query.
  """
  def covered_occurrence_keys(%Scope{user: user}) do
    from(je in JournalEntry,
      where: je.user_id == ^user.id and not is_nil(je.recurring_expense_id),
      select: {je.recurring_expense_id, je.date}
    )
    |> Repo.all()
    |> MapSet.new(fn {expense_id, %Date{} = date} -> {expense_id, {date.year, date.month}} end)
  end

  def covered_occurrence?(covered_keys, %RecurringExpense{} = expense, %Date{} = date) do
    MapSet.member?(covered_keys, {expense.id, {date.year, date.month}})
  end

  # ---------------------------------------------------------------------------
  # Reconciliation with journal entries
  # ---------------------------------------------------------------------------

  @doc """
  Journal entries already linked to `expense`, most recent first.
  """
  def linked_journal_entries(%Scope{} = scope, %RecurringExpense{} = expense) do
    true = expense.user_id == scope.user.id

    from(je in JournalEntry,
      where: je.recurring_expense_id == ^expense.id,
      order_by: [desc: je.date]
    )
    |> Repo.all()
  end

  @doc """
  Unlinked journal entries that could plausibly cover the occurrence due
  around `around` (same user, same amount, date within the candidate window).
  """
  def candidate_entries(%Scope{} = scope, %RecurringExpense{} = expense, %Date{} = around) do
    true = expense.user_id == scope.user.id

    from(je in JournalEntry,
      where:
        je.user_id == ^scope.user.id and
          is_nil(je.recurring_expense_id) and
          je.amount_cents == ^expense.amount_cents and
          je.date >= ^Date.add(around, -@candidate_window_days) and
          je.date <= ^Date.add(around, @candidate_window_days),
      order_by: [asc: je.date]
    )
    |> Repo.all()
  end

  @doc """
  Links `journal_entry` to `expense`, marking the occurrence as covered.
  Both records must belong to the current user.
  """
  def link_journal_entry(%Scope{} = scope, %RecurringExpense{} = expense, %JournalEntry{} = entry) do
    true = expense.user_id == scope.user.id
    true = entry.user_id == scope.user.id

    entry
    |> Ecto.Changeset.change(recurring_expense_id: expense.id)
    |> Repo.update()
  end

  @doc """
  Clears the link on `journal_entry`. The entry itself is kept.

  Reloads the row first: Ecto's `change/2` drops changes whose value already
  matches the struct's current field, so a stale struct that still carries
  `recurring_expense_id: nil` would otherwise make the unlink a silent no-op.
  """
  def unlink_journal_entry(%Scope{} = scope, %JournalEntry{} = entry) do
    true = entry.user_id == scope.user.id

    entry
    |> Repo.reload!()
    |> Ecto.Changeset.change(recurring_expense_id: nil)
    |> Repo.update()
  end
end
