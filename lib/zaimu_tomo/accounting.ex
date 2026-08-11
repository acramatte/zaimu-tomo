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
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog
  alias Ecto.Multi

  # ---------------------------------------------------------------------------
  # Entry creation (called after invoice approval / amendment)
  # ---------------------------------------------------------------------------

  @spec create_from_decision(struct(), map()) :: {:ok, JournalEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_from_decision(%ReviewDecision{} = decision, tax_claim_attrs \\ %{}) do
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

    tax_claim_attrs = normalize_tax_claim_attrs(attrs.amount_cents, tax_claim_attrs)

    Multi.new()
    |> Multi.insert(:journal_entry, JournalEntry.changeset_for_create(attrs))
    |> Multi.run(:tax_deduction_claim, fn repo, %{journal_entry: entry} ->
      TaxDeductionClaim.changeset_for_create(entry, tax_claim_attrs) |> repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{journal_entry: entry, tax_deduction_claim: claim}} ->
        {:ok, %{entry | tax_deduction_claim: claim}}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Posting (category assignment)
  # ---------------------------------------------------------------------------

  @spec change_journal_entry_posting(JournalEntry.t(), map()) :: Ecto.Changeset.t()
  def change_journal_entry_posting(%JournalEntry{} = entry, attrs \\ %{}) do
    JournalEntry.changeset_for_categorize(entry, attrs)
  end

  @spec post_entry(JournalEntry.t(), integer(), String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, JournalEntry.t()} | {:error, Ecto.Changeset.t()}
  def post_entry(
        %JournalEntry{} = entry,
        user_id,
        category,
        need_or_want,
        notes \\ nil,
        tax_claim_attrs \\ %{}
      ) do
    true = entry.user_id == user_id

    Multi.new()
    |> Multi.update(
      :journal_entry,
      JournalEntry.changeset_for_categorize(entry, %{
        category: category,
        need_or_want: need_or_want,
        notes: notes,
        status: "posted"
      })
    )
    |> Multi.run(:tax_deduction_claim, fn repo, %{journal_entry: updated} ->
      upsert_tax_deduction_claim(repo, updated, tax_claim_attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{journal_entry: updated, tax_deduction_claim: claim}} ->
        updated = %{updated | tax_deduction_claim: claim}

        write_event_log("journal_entry_posted", entry.id, user_id, %{
          category: category,
          need_or_want: need_or_want,
          tax_deduction_status: claim.status
        })

        {:ok, updated}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns posted spending totals for the current UTC month.

  Until currency conversion is introduced, amounts in every source currency
  are treated as equivalent and displayed using the user's base currency.
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
  def monthly_spending(%Scope{user: user}, %Date{} = reference_date) do
    user_id = user.id
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
      currency: user.base_currency,
      total_cents: Enum.sum_by(categories, & &1.total_cents),
      entry_count: Enum.sum_by(categories, & &1.entry_count),
      categories: categories
    }
  end

  @spec list_journal_entries(integer()) :: [JournalEntry.t()]
  def list_journal_entries(user_id) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id,
      preload: [:tax_deduction_claim],
      order_by: [
        asc: fragment("CASE WHEN ? = 'uncategorized' THEN 0 ELSE 1 END", je.status),
        desc: je.date,
        desc: je.inserted_at
      ]
    )
    |> Repo.all()
  end

  @spec get_journal_entry(integer(), integer()) :: {:ok, JournalEntry.t()} | {:error, String.t()}
  def get_journal_entry(id, user_id) do
    case Repo.one(
           from je in JournalEntry,
             where: je.id == ^id and je.user_id == ^user_id,
             preload: [:tax_deduction_claim]
         ) do
      nil -> {:error, "Journal entry not found or not owned by user"}
      entry -> {:ok, entry}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp upsert_tax_deduction_claim(repo, %JournalEntry{} = entry, attrs) do
    attrs = normalize_tax_claim_attrs(entry.amount_cents, attrs)

    case repo.get_by(TaxDeductionClaim, journal_entry_id: entry.id) do
      nil ->
        TaxDeductionClaim.changeset_for_create(entry, attrs) |> repo.insert()

      claim ->
        TaxDeductionClaim.changeset_for_update(claim, attrs) |> repo.update()
    end
  end

  defp normalize_tax_claim_attrs(amount_cents, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    status = Map.get(attrs, "status", "undecided")

    Map.put_new_lazy(attrs, "deductible_amount_cents", fn ->
      if status in ["not_deductible", "disallowed"], do: 0, else: amount_cents
    end)
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
