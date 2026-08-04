defmodule ZaimuTomo.RecurringExpenses.RecurringExpense do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Currency

  @frequencies [:monthly, :quarterly, :yearly]

  schema "recurring_expenses" do
    field :name, :string
    field :amount_cents, :integer
    field :currency, :string
    field :frequency, Ecto.Enum, values: @frequencies
    field :start_date, :date
    field :end_date, :date
    field :user_id, :id

    has_many :journal_entries, ZaimuTomo.Accounting.JournalEntry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(recurring_expense, attrs, user_scope) do
    recurring_expense
    |> cast(attrs, [:name, :amount_cents, :currency, :frequency, :start_date, :end_date])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :amount_cents, :currency, :frequency, :start_date])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_end_date_not_before_start_date()
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, max: 255)
    |> put_change(:user_id, user_scope.user.id)
  end

  def frequency_values, do: @frequencies

  # ---------------------------------------------------------------------------
  # Occurrence math (pure; no Repo access)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the occurrence dates of `expense` within the inclusive range
  `[from, to]`.

  The first occurrence is the start date itself. Occurrences respect the
  optional end date (inclusive). Day-of-month clamping: an expense anchored
  on the 31st recurs on the last day of shorter months (Feb 28/29), and a
  Feb-29 anchor falls back to Feb 28 in non-leap years.
  """
  def occurrences(%__MODULE__{} = expense, %Date{} = from, %Date{} = to) do
    expense
    |> anchor_months(from, to)
    |> Enum.map(&clamp_day(&1, expense.start_date.day))
    |> Enum.filter(fn date ->
      Date.compare(date, from) != :lt and Date.compare(date, to) != :gt
    end)
    |> Enum.filter(&active_on?(expense, &1))
  end

  @doc """
  Returns the first occurrence of `expense` on or after `from`, or `nil` when
  the expense has no remaining occurrence (e.g. it already ended).
  """
  def next_occurrence(%__MODULE__{} = expense, %Date{} = from) do
    expense
    |> occurrences(from, Date.add(from, 370))
    |> List.first()
  end

  # Months in [beginning_of_month(from), beginning_of_month(to)] that carry an
  # occurrence of the expense.
  defp anchor_months(%__MODULE__{} = expense, %Date{} = from, %Date{} = to) do
    first_month = Date.beginning_of_month(from)
    last_month = Date.beginning_of_month(to)

    Stream.iterate(first_month, &next_month/1)
    |> Enum.take_while(fn month -> Date.compare(month, last_month) != :gt end)
    |> Enum.filter(&anchors?(&1, expense))
  end

  defp anchors?(_month, %__MODULE__{frequency: :monthly}), do: true

  defp anchors?(month, %__MODULE__{frequency: :quarterly, start_date: start_date}) do
    rem(months_between(start_date, month), 3) == 0
  end

  defp anchors?(month, %__MODULE__{frequency: :yearly, start_date: start_date}) do
    month.month == start_date.month
  end

  defp months_between(%Date{} = earlier, %Date{} = later) do
    (later.year - earlier.year) * 12 + (later.month - earlier.month)
  end

  defp next_month(%Date{} = date) do
    date
    |> Date.add(32)
    |> Date.beginning_of_month()
  end

  defp clamp_day(%Date{} = date, day), do: %{date | day: min(day, Date.days_in_month(date))}

  defp active_on?(%__MODULE__{} = expense, %Date{} = date) do
    Date.compare(date, expense.start_date) != :lt and
      (is_nil(expense.end_date) or Date.compare(date, expense.end_date) != :gt)
  end

  defp validate_end_date_not_before_start_date(changeset) do
    with %Date{} = start_date <- get_change(changeset, :start_date),
         %Date{} = end_date <- get_change(changeset, :end_date),
         true <- Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :end_date, "must be on or after the start date")
    else
      _ -> changeset
    end
  end
end
