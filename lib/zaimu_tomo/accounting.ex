defmodule ZaimuTomo.Accounting do
  @moduledoc """
  Context for budget journal entries.

  Journal entries are created automatically from approved/amended invoices.
  A human assigns a budget category to post each entry.
  """

  import Ecto.Query, warn: false
  require Logger

  alias ZaimuTomo.Repo
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Review.EventLog

  # ---------------------------------------------------------------------------
  # Entry creation (called after invoice approval / amendment)
  # ---------------------------------------------------------------------------

  def create_from_decision(%ReviewDecision{} = decision) do
    data = ReviewDecision.effective_data(decision)

    attrs = %{
      review_decision_id: decision.id,
      user_id: decision.user_id,
      amount_cents: parse_integer(data["amount_to_pay_cents"]),
      currency: data["currency"],
      date: parse_date(data["invoice_date"]),
      description: data["reason_for_payment"],
      issuer: data["issuer"],
      invoice_number: data["invoice_number"],
      status: "uncategorized"
    }

    JournalEntry.changeset_for_create(attrs) |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Posting (category assignment)
  # ---------------------------------------------------------------------------

  def post_entry(%JournalEntry{} = entry, user_id, category, notes \\ nil) do
    true = entry.user_id == user_id

    case JournalEntry.changeset_for_categorize(entry, %{
           category: category,
           notes: notes,
           status: "posted"
         })
         |> Repo.update() do
      {:ok, updated} ->
        write_event_log("journal_entry_posted", entry.id, user_id, %{category: category})
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

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

  defp parse_date(nil), do: nil
  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
  defp parse_date(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp parse_integer(_), do: nil

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
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to write event log for #{event_type}: #{inspect(reason)}")
        :ok
    end
  end
end
