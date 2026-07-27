defmodule ZaimuTomo.Accounting do
  @moduledoc """
  Context for budget journal entries.

  Journal entries are created automatically from approved/amended invoices.
  A human assigns a budget category and need/want classification to post each entry.
  """

  import Ecto.Query, warn: false
  require Logger

  alias ZaimuTomo.Repo
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog

  # ---------------------------------------------------------------------------
  # Entry creation (called after invoice approval / amendment)
  # ---------------------------------------------------------------------------

  def create_from_decision(%ReviewDecision{} = decision) do
    data = decision.decision_data || decision.original_data

    attrs = %{
      review_decision_id: decision.id,
      user_id: decision.user_id,
      amount_cents: data.amount_to_pay_cents,
      currency: data.currency,
      date: parse_date(data.invoice_date),
      description: data.reason_for_payment,
      issuer: data.issuer,
      invoice_number: data.invoice_number,
      status: "uncategorized"
    }

    JournalEntry.changeset_for_create(attrs) |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Posting (category assignment)
  # ---------------------------------------------------------------------------

  def change_journal_entry_posting(%JournalEntry{} = entry, attrs \\ %{}) do
    JournalEntry.changeset_for_categorize(entry, attrs)
  end

  def post_entry(%JournalEntry{} = entry, user_id, category, need_or_want, notes \\ nil) do
    true = entry.user_id == user_id

    case JournalEntry.changeset_for_categorize(entry, %{
           category: category,
           need_or_want: need_or_want,
           notes: notes,
           status: "posted"
         })
         |> Repo.update() do
      {:ok, updated} ->
        write_event_log("journal_entry_posted", entry.id, user_id, %{
          category: category,
          need_or_want: need_or_want
        })

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns posted spending totals for the current UTC month.

  Until currency conversion is introduced, amounts in every source currency
  are treated as equivalent and displayed using the configured currency hint.
  """
  def current_month_spending(%Scope{} = scope) do
    current_month_spending(scope, Date.utc_today())
  end

  @doc """
  Returns posted spending totals for the month containing `reference_date`.

  The explicit date keeps month-boundary behavior deterministic for callers
  such as tests and historical reports.
  """
  def current_month_spending(%Scope{} = scope, %Date{} = reference_date) do
    monthly_spending(scope, reference_date)
  end

  @doc """
  Returns posted spending totals for the month containing `reference_date`.
  """
  def monthly_spending(%Scope{user: %{id: user_id}}, %Date{} = reference_date) do
    month_start = Date.beginning_of_month(reference_date)
    next_month_start = month_start |> Date.add(32) |> Date.beginning_of_month()

    categories =
      from(je in JournalEntry,
        where:
          je.user_id == ^user_id and
            je.status == "posted" and
            not is_nil(je.category) and
            fragment("btrim(?) <> ''", je.category) and
            je.date >= ^month_start and
            je.date < ^next_month_start,
        group_by: fragment("lower(btrim(?))", je.category),
        order_by: [desc: sum(je.amount_cents)],
        select: %{
          category: fragment("lower(btrim(?))", je.category),
          total_cents: sum(je.amount_cents),
          entry_count: count(je.id)
        }
      )
      |> Repo.all()
      |> Enum.map(fn category ->
        %{category | category: humanize_category(category.category)}
      end)

    %{
      month_start: month_start,
      currency: configured_currency(),
      total_cents: Enum.sum_by(categories, & &1.total_cents),
      entry_count: Enum.sum_by(categories, & &1.entry_count),
      categories: categories
    }
  end

  def list_journal_entries(user_id) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id,
      order_by: [
        asc: fragment("CASE WHEN ? = 'uncategorized' THEN 0 ELSE 1 END", je.status),
        desc: je.date,
        desc: je.inserted_at
      ]
    )
    |> Repo.all()
  end

  def get_journal_entry(id, user_id) do
    case Repo.get_by(JournalEntry, id: id, user_id: user_id) do
      nil -> {:error, "Journal entry not found or not owned by user"}
      entry -> {:ok, entry}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp configured_currency do
    :zaimu_tomo
    |> Application.get_env(:ai_workflow, [])
    |> Keyword.get(:currency_hint, "CHF")
    |> String.upcase()
  end

  defp humanize_category(category) do
    category
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(" ", &capitalize_word/1)
  end

  defp capitalize_word(word) do
    case String.next_grapheme(word) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> word
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp write_event_log(event_type, entry_id, user_id, metadata) do
    result =
      EventLog.changeset_for_create(%{
        event_type: event_type,
        invoice_id: to_string(entry_id),
        user_id: user_id,
        metadata: metadata,
        status: "completed"
      })
      |> Repo.insert()

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write event log for #{event_type}: #{inspect(reason)}")
        :ok
    end
  end
end
