defmodule ZaimuTomo.Accounting.LegacyBookingBackfill do
  @moduledoc """
  One-off backfill for journal entries that predate booking at posting time and
  are still missing a category or a need/want choice.

  An entry is completed only when the same user's posted entries from the same
  issuer (compared like the duplicate index, trimmed and case-insensitive) agree
  on every missing value. Values the entry already has are kept. Anything else
  is reported for a person to book, so nothing is guessed from a similar name.

  Bookings a person already decided are passed at run time as `:manual`, so no
  real ledger data lives in the repository. They are keyed by entry ID and
  normalized issuer so they cannot land on another row, and go through
  `Accounting.post_entry/6`, exactly like the invoice page's Book form.

  It is a dry run unless called with `confirm: true`. Each entry is updated in
  its own transaction together with a `journal_entry_posted` event marked with
  `source: "legacy_booking_backfill"` that records the prior state. For those copied bookings, tax claims and notes
  are left alone, and `updated_at` is kept so old entries do not jump to the top
  of the journal.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.ReviewDecision

  @source "legacy_booking_backfill"

  @type match :: %{
          required(:entry) => JournalEntry.t(),
          required(:document_id) => integer(),
          required(:category) => String.t(),
          required(:need_or_want) => String.t(),
          required(:source) => :precedent | :manual,
          optional(:precedent_count) => pos_integer(),
          optional(:tax_status) => String.t() | nil
        }

  @type unmatched :: %{
          entry: JournalEntry.t(),
          document_id: integer(),
          reason: :no_history | :conflicting_history
        }

  @type summary :: %{
          confirmed: boolean(),
          matched: [match()],
          applied: [match()],
          unmatched: [unmatched()],
          failed: [%{match: match(), errors: term()}]
        }

  @doc """
  Plans the backfill and, with `confirm: true`, applies it.

  Returns `{:error, summary}` only when an update failed. Unmatched entries are
  expected and left for manual booking.

  Options:

    * `:confirm` - apply the plan instead of only reporting it.
    * `:manual` - decided bookings as a map of `{entry_id, normalized_issuer}`
      to `%{category: _, need_or_want: _, tax_status: _}`. Defaults to none.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, summary()}
  def run(opts \\ []) do
    confirmed = Keyword.get(opts, :confirm, false)
    %{matched: matched, unmatched: unmatched} = plan(Keyword.get(opts, :manual, %{}))
    %{applied: applied, failed: failed} = apply_matches(matched, confirmed)

    summary = %{
      confirmed: confirmed,
      matched: matched,
      applied: applied,
      unmatched: unmatched,
      failed: failed
    }

    {if(failed == [], do: :ok, else: :error), summary}
  end

  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    verb = if summary.confirmed, do: "Booked", else: "Would book"
    mode = if summary.confirmed, do: "applied", else: "dry run"

    [
      "Legacy booking backfill (#{mode}): matched=#{length(summary.matched)} " <>
        "applied=#{length(summary.applied)} unmatched=#{length(summary.unmatched)} " <>
        "failed=#{length(summary.failed)}",
      Enum.map(summary.matched, &format_match(&1, verb)),
      Enum.map(summary.unmatched, &format_unmatched/1),
      Enum.map(summary.failed, &format_failure/1),
      if(summary.confirmed, do: [], else: "Nothing changed. Re-run with confirm: true to apply.")
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp plan(manual) do
    precedents = precedents()

    targets()
    |> Enum.map(&classify(&1, precedents, manual))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> then(&%{matched: Map.get(&1, :matched, []), unmatched: Map.get(&1, :unmatched, [])})
  end

  defp targets do
    Repo.all(
      from e in JournalEntry,
        join: d in ReviewDecision,
        on: d.id == e.review_decision_id,
        join: c in ExtractedContent,
        on: c.id == d.extracted_content_id,
        left_join: t in TaxDeductionClaim,
        on: t.journal_entry_id == e.id,
        where: is_nil(e.category) or is_nil(e.need_or_want),
        order_by: e.id,
        select: %{
          entry: e,
          document_id: c.document_id,
          tax_status: t.status,
          issuer_key: fragment("lower(btrim(?))", e.issuer)
        }
    )
  end

  defp precedents do
    from(e in JournalEntry,
      where: e.status == "posted",
      where: not is_nil(e.category) and not is_nil(e.need_or_want),
      where: fragment("btrim(?) <> ''", e.issuer),
      group_by: [e.user_id, fragment("lower(btrim(?))", e.issuer), e.category, e.need_or_want],
      select: %{
        user_id: e.user_id,
        issuer_key: fragment("lower(btrim(?))", e.issuer),
        category: e.category,
        need_or_want: e.need_or_want,
        count: count(e.id)
      }
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.user_id, &1.issuer_key})
  end

  defp classify(%{entry: entry, issuer_key: issuer_key} = target, precedents, manual) do
    row = Map.take(target, [:entry, :document_id, :tax_status])

    case Map.fetch(manual, {entry.id, issuer_key}) do
      {:ok, decision} -> {:matched, row |> Map.merge(decision) |> Map.put(:source, :manual)}
      :error -> classify_from_history(row, Map.get(precedents, {entry.user_id, issuer_key}, []))
    end
  end

  defp classify_from_history(%{entry: entry} = row, history) do
    case history |> Enum.map(&completed_booking(entry, &1)) |> Enum.uniq() do
      [] ->
        {:unmatched, Map.put(row, :reason, :no_history)}

      [{category, need_or_want}] ->
        precedent_count = history |> Enum.map(& &1.count) |> Enum.sum()

        {:matched,
         Map.merge(row, %{
           category: category,
           need_or_want: need_or_want,
           precedent_count: precedent_count,
           source: :precedent
         })}

      _conflicting ->
        {:unmatched, Map.put(row, :reason, :conflicting_history)}
    end
  end

  # Precedents only need to agree on what the entry is missing.
  defp completed_booking(entry, precedent) do
    {entry.category || precedent.category, entry.need_or_want || precedent.need_or_want}
  end

  defp apply_matches(_matched, false), do: %{applied: [], failed: []}

  defp apply_matches(matched, true) do
    results = Enum.map(matched, &{&1, apply_match(&1)})

    %{
      applied: for({match, {:ok, _}} <- results, do: match),
      failed:
        for({match, {:error, changeset}} <- results) do
          %{match: match, errors: changeset.errors}
        end
    }
  end

  defp apply_match(%{source: :manual, entry: entry} = match) do
    Accounting.post_entry(
      entry,
      entry.user_id,
      match.category,
      match.need_or_want,
      entry.notes,
      %{"status" => match.tax_status}
    )
  end

  defp apply_match(%{source: :precedent} = match) do
    Multi.new()
    |> Multi.update(:entry, booking_changeset(match))
    |> Multi.insert(:event, &event_changeset(&1.entry, match))
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp booking_changeset(%{entry: entry} = match) do
    entry
    |> JournalEntry.changeset_for_categorize(%{
      category: match.category,
      need_or_want: match.need_or_want,
      status: "posted"
    })
    |> Ecto.Changeset.force_change(:updated_at, entry.updated_at)
  end

  defp event_changeset(booked_entry, %{entry: previous} = match) do
    Accounting.posted_event_changeset(booked_entry, match.tax_status, %{
      source: @source,
      precedent_count: match.precedent_count,
      previous_status: previous.status,
      previous_category: previous.category,
      previous_need_or_want: previous.need_or_want
    })
  end

  defp format_match(%{entry: entry} = match, verb) do
    "#{verb} entry #{entry.id} (#{entry.issuer}) as #{match.category} / #{match.need_or_want} " <>
      match_origin(match) <> "."
  end

  defp match_origin(%{source: :manual, tax_status: tax_status}),
    do: "from a manual decision, tax status #{tax_status}"

  defp match_origin(%{source: :precedent, precedent_count: count}),
    do: "from #{count} earlier posting(s)"

  defp format_unmatched(%{entry: entry, document_id: document_id, reason: reason}) do
    "Book by hand: entry #{entry.id} (#{entry.issuer}) at /documents/#{document_id}: " <>
      unmatched_reason(reason) <> "."
  end

  defp unmatched_reason(:no_history), do: "no earlier posting from this issuer"
  defp unmatched_reason(:conflicting_history), do: "earlier postings disagree"

  defp format_failure(%{match: %{entry: entry}, errors: errors}) do
    "Failed entry #{entry.id}: #{inspect(errors)}"
  end
end
