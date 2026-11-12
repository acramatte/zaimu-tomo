defmodule ZaimuTomo.Accounting do
  @moduledoc """
  Context for budget journal entries.

  Journal entries are created automatically from approved/amended invoices.
  A human assigns a budget category and need/want classification to post each entry.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Review.ReviewDecision

  # ---------------------------------------------------------------------------
  # Duplicate detection
  # ---------------------------------------------------------------------------

  @doc """
  Returns journal entries already recorded for this user that appear to be the
  same invoice as `data` (an `%ExtractedData{}` with the invoice's final,
  reviewer-confirmed values).

  * With an invoice number, the strong match is (user, issuer, invoice number),
    compared case-insensitively with surrounding whitespace trimmed.
  * Without a number, a soft match requires the exact tuple (issuer, date,
    amount, currency). A missing component never matches.

  Candidates from other users are never returned.
  """
  @spec duplicate_candidates(integer() | nil, ExtractedData.t()) :: [JournalEntry.t()]
  def duplicate_candidates(nil, %ExtractedData{}), do: []

  def duplicate_candidates(user_id, %ExtractedData{} = data) do
    base =
      from(je in JournalEntry,
        where: je.user_id == ^user_id,
        where: fragment("lower(btrim(?)) = lower(btrim(?))", je.issuer, ^data.issuer),
        order_by: [desc: je.inserted_at],
        limit: 5
      )

    base
    |> candidate_filters(data)
    |> Repo.all()
  end

  @typedoc """
  Why a journal entry is a duplicate candidate, strongest first: the same
  uploaded file, the same (issuer, invoice number), or the same
  (issuer, date, amount, currency) tuple.
  """
  @type match_reason :: :same_file | :invoice_number | :same_details

  @typedoc """
  The outcome of `duplicate_check/3`.

  * `:none` — no candidate; post freely.
  * `:possible` — only a soft (issuer, date, amount, currency) match; posting
    needs the existing explicit "post anyway" confirmation.
  * `:file_reuse` — the same uploaded file and nothing else matches; posting
    needs an explicit file-reuse confirmation (for example, a reused QR-bill).
  * `:invoice_number` — the invoice number is already recorded for the issuer;
    blocked until the data is amended.
  * `:same_file_blocked` — the same uploaded file and the invoice facts also
    match; blocked, the review should be rejected.
  """
  @type verdict :: :none | :possible | :file_reuse | :invoice_number | :same_file_blocked

  @type duplicate_check :: %{
          verdict: verdict(),
          candidates: [%{entry: JournalEntry.t(), reason: match_reason()}]
        }

  @doc """
  Checks `data` (the invoice's final values) and the source document's
  fingerprint against the user's journal entries.

  Combines `duplicate_candidates/2` with an exact match on
  `source_document_sha256`. A candidate matching several rules is listed once
  with its strongest reason. An exact-file match is confirmable as a reuse only
  when neither field rule matches; the (issuer, date, amount, currency) tuple
  is also compared against the file-matched entries even when `data` has an
  invoice number, so the same file with the same facts is never confirmable.

  A nil fingerprint never matches, and other users' entries are never queried.
  """
  @spec duplicate_check(integer() | nil, ExtractedData.t(), String.t() | nil) ::
          duplicate_check()
  def duplicate_check(nil, %ExtractedData{}, _source_sha256),
    do: %{verdict: :none, candidates: []}

  def duplicate_check(user_id, %ExtractedData{} = data, source_sha256) do
    field_matches = duplicate_candidates(user_id, data)
    file_matches = file_candidates(user_id, source_sha256)
    field_reason = if strong_match?(data, field_matches), do: :invoice_number, else: :same_details

    verdict =
      cond do
        file_matches != [] and
            (field_matches != [] or same_details_as_file_match?(user_id, data, file_matches)) ->
          :same_file_blocked

        file_matches != [] ->
          :file_reuse

        field_reason == :invoice_number ->
          :invoice_number

        field_matches != [] ->
          :possible

        true ->
          :none
      end

    candidates =
      Enum.map(file_matches, &%{entry: &1, reason: :same_file}) ++
        Enum.map(field_matches, &%{entry: &1, reason: field_reason})

    %{verdict: verdict, candidates: Enum.uniq_by(candidates, & &1.entry.id)}
  end

  @doc "True when a `duplicate_check/3` verdict forbids posting outright."
  @spec blocked?(duplicate_check()) :: boolean()
  def blocked?(%{verdict: verdict}), do: verdict in [:invoice_number, :same_file_blocked]

  defp file_candidates(_user_id, nil), do: []

  defp file_candidates(user_id, source_sha256) when is_binary(source_sha256) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id and je.source_document_sha256 == ^source_sha256,
      order_by: [desc: je.inserted_at, desc: je.id]
    )
    |> Repo.all()
  end

  defp same_details_as_file_match?(user_id, data, file_matches) do
    ids = Enum.map(file_matches, & &1.id)

    from(je in JournalEntry,
      where: je.user_id == ^user_id and je.id in ^ids,
      where: fragment("lower(btrim(?)) = lower(btrim(?))", je.issuer, ^data.issuer),
      select: count(je.id)
    )
    |> soft_match_filters(data)
    |> Repo.one()
    |> Kernel.>(0)
  end

  # Numbered and unnumbered matches are mutually exclusive: a nonblank invoice
  # number is the identity, otherwise the exact tuple is compared.
  defp candidate_filters(query, %ExtractedData{invoice_number: number} = data) do
    if invoice_number?(number) do
      where(
        query,
        [je],
        fragment("lower(btrim(?)) = lower(btrim(?))", je.invoice_number, ^number)
      )
    else
      soft_match_filters(query, data)
    end
  end

  # The unnumbered tuple needs every component; a missing or malformed one
  # (for example, a nil amount or a non-ISO date) never matches.
  defp soft_match_filters(query, %ExtractedData{
         amount_to_pay_cents: amount,
         invoice_date: invoice_date,
         currency: currency
       })
       when is_integer(amount) and is_binary(invoice_date) and is_binary(currency) do
    with false <- String.trim(currency) == "",
         {:ok, date} <- Date.from_iso8601(invoice_date) do
      where(
        query,
        [je],
        je.date == ^date and
          je.amount_cents == ^amount and
          fragment("lower(btrim(?)) = lower(btrim(?))", je.currency, ^currency)
      )
    else
      _ -> where(query, false)
    end
  end

  defp soft_match_filters(query, %ExtractedData{}), do: where(query, false)

  defp invoice_number?(number), do: is_binary(number) and String.trim(number) != ""

  # ---------------------------------------------------------------------------
  # Entry creation (called after invoice approval / amendment)
  # ---------------------------------------------------------------------------

  @doc """
  Builds an `Ecto.Multi` that creates the journal entry and its tax deduction
  claim for an approved/amended review decision.

  Only `ZaimuTomo.Review`'s posting transaction composes this multi. That
  transaction takes the user's posting lock and runs the duplicate gate
  first, so composing it anywhere else would post without either. The step
  names (`:journal_entry`, `:tax_deduction_claim`) are stable for that
  composition.

  Options:

    * `:source_document_sha256` — the source document's fingerprint, copied
      to the entry as an immutable posting-time snapshot.
    * `:source_file_reuse_confirmed` — `true` only when the reviewer explicitly
      confirmed a reuse of the same file; defaults to `false`.
    * `:booking` — a map with `category`, `need_or_want` and `notes`. When
      given, the entry is categorized and posted in the same multi (step
      `:posted_journal_entry`), so an invoice can be checked and booked in one
      step. Without it the entry stays `uncategorized`.
  """
  @spec create_multi_from_decision(ReviewDecision.t(), map(), keyword()) :: Ecto.Multi.t()
  def create_multi_from_decision(
        %ReviewDecision{} = decision,
        tax_claim_attrs \\ %{},
        opts \\ []
      ) do
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
      status: "uncategorized",
      source_document_sha256: Keyword.get(opts, :source_document_sha256),
      source_file_reuse_confirmed: Keyword.get(opts, :source_file_reuse_confirmed, false)
    }

    tax_claim_attrs = normalize_tax_claim_attrs(attrs.amount_cents, tax_claim_attrs)

    Multi.new()
    |> Multi.insert(:journal_entry, JournalEntry.changeset_for_create(attrs))
    |> Multi.run(:tax_deduction_claim, fn repo, %{journal_entry: entry} ->
      TaxDeductionClaim.changeset_for_create(entry, tax_claim_attrs) |> repo.insert()
    end)
    |> maybe_post_booking(Keyword.get(opts, :booking))
  end

  defp maybe_post_booking(multi, nil), do: multi

  defp maybe_post_booking(multi, booking) when is_map(booking) do
    Multi.update(multi, :posted_journal_entry, fn %{journal_entry: entry} ->
      booking = Map.new(booking, fn {key, value} -> {to_string(key), value} end)

      JournalEntry.changeset_for_categorize(entry, booking)
    end)
    |> Multi.insert(:posted_event, fn %{posted_journal_entry: entry, tax_deduction_claim: claim} ->
      posted_event_changeset(entry, claim.status)
    end)
  end

  @doc """
  True when a journal-entry insert failed on the unique
  (user, issuer, invoice number) index or the unique (user, source file
  digest) index over unconfirmed postings.

  Matches the constraint name rather than the error message, so unrelated
  changeset errors are never mistaken for a duplicate.
  """
  @spec duplicate_error?(Ecto.Changeset.t()) :: boolean()
  def duplicate_error?(%Ecto.Changeset{errors: errors}) do
    duplicate_indexes = [
      JournalEntry.duplicate_invoice_index(),
      JournalEntry.duplicate_source_file_index()
    ]

    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and opts[:constraint_name] in duplicate_indexes
    end)
  end

  def duplicate_error?(_other), do: false

  @doc """
  Fetches the journal entry created for a review decision, if any.
  """
  @spec get_journal_entry_for_decision(integer() | String.t()) ::
          {:ok, JournalEntry.t()} | :error
  def get_journal_entry_for_decision(review_decision_id) do
    case Repo.get_by(JournalEntry, review_decision_id: review_decision_id) do
      nil ->
        :error

      entry ->
        {:ok, Repo.preload(entry, :tax_deduction_claim)}
    end
  end

  @doc """
  True when `candidates` (from `duplicate_candidates/2` for the same `data`)
  matched on the invoice number — the strong, blocking kind of duplicate.

  Strength follows the rule that matched, which is decided by whether `data`
  has an invoice number; a numbered entry found through the unnumbered tuple
  is only a possible duplicate.
  """
  @spec strong_match?(ExtractedData.t(), [JournalEntry.t()]) :: boolean()
  def strong_match?(%ExtractedData{}, []), do: false

  def strong_match?(%ExtractedData{invoice_number: number}, [_ | _]),
    do: invoice_number?(number)

  # ---------------------------------------------------------------------------
  # Posting (category assignment)
  # ---------------------------------------------------------------------------

  @doc """
  Books an uncategorized entry: saves its category, need/want choice and tax
  treatment and writes the `journal_entry_posted` event, in one transaction.

  Posting happens once. The entry row is locked and must still be
  `uncategorized`; for an entry that is already posted this returns
  `{:error, :already_posted}` and changes nothing. From then on the tax
  treatment only moves through `revise_tax_deduction_claim/3`, so
  `tax_claim_attrs` takes a draft status only.
  """
  @spec post_entry(JournalEntry.t(), integer(), String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, JournalEntry.t()} | {:error, :already_posted | Ecto.Changeset.t()}
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
    |> Multi.run(:unposted_entry, fn repo, _changes -> fetch_unposted_entry(repo, entry.id) end)
    |> Multi.update(:journal_entry, fn %{unposted_entry: unposted} ->
      JournalEntry.changeset_for_categorize(unposted, %{
        category: category,
        need_or_want: need_or_want,
        notes: notes
      })
    end)
    |> Multi.run(:tax_deduction_claim, fn repo, %{journal_entry: updated} ->
      upsert_tax_deduction_claim(repo, updated, tax_claim_attrs)
    end)
    |> Multi.insert(:posted_event, fn %{journal_entry: updated, tax_deduction_claim: claim} ->
      posted_event_changeset(updated, claim.status)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{journal_entry: updated, tax_deduction_claim: claim}} ->
        {:ok, %{updated | tax_deduction_claim: claim}}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Revises the tax deduction claim of the scoped user's posted journal entry,
  for example after the tax office disallows a claimed deduction.

  `attrs` (string or atom keys):

    * `"status"` — required; one of `TaxDeductionClaim.next_statuses/1` for
      the current status.
    * `"reason"` — stored as the claim's notes and in the audit event.
      Required for a correction (`claimed` → `candidate`, `disallowed` →
      `claimed`).
    * `"tax_return_reference"` — required for `claimed`.
    * `"authority_name"`, `"authority_reference"` — required for `disallowed`.
    * `"deductible_amount_cents"` — optional integer between 0 and the entry
      amount (which is negative for a credit note). Defaults to the entry
      amount. Always 0 for `not_deductible` and `disallowed`.

  The claim update and a `tax_deduction_claim_revised` event log entry (old
  and new status and amount, the reason, the references, and whether it was
  a correction) commit in one transaction, so a
  revision is never applied without its audit record. Saving an unchanged
  claim logs nothing. An entry posted before
  tax claims existed has none; the revision creates it, with no old values.

  Returns `{:error, :not_found}` for another user's or a missing entry, and
  `{:error, :not_posted}` while the entry is still uncategorized.
  """
  @spec revise_tax_deduction_claim(Scope.t(), JournalEntry.t(), map()) ::
          {:ok, JournalEntry.t()} | {:error, :not_found | :not_posted | Ecto.Changeset.t()}
  def revise_tax_deduction_claim(%Scope{user: user}, %JournalEntry{id: entry_id}, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Multi.new()
    |> Multi.run(:journal_entry, fn repo, _changes -> fetch_posted_entry(repo, user, entry_id) end)
    |> Multi.run(:previous_claim, fn repo, %{journal_entry: entry} -> lock_claim(repo, entry) end)
    |> Multi.run(:tax_deduction_claim, fn repo, %{journal_entry: entry, previous_claim: claim} ->
      save_revised_claim(repo, entry, claim, attrs)
    end)
    |> Multi.run(:event_log, fn repo, %{previous_claim: previous, tax_deduction_claim: revised} ->
      insert_revision_event(repo, user, entry_id, previous, revised)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{journal_entry: entry, tax_deduction_claim: claim}} ->
        {:ok, %{entry | tax_deduction_claim: claim}}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
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

  @doc """
  Returns the distinct categories the scoped user has already assigned, sorted
  alphabetically, for autocompleting the posting form.

  Categories differing only in case or surrounding whitespace collapse into
  one suggestion spelled as most recently used. Other users' categories are
  never returned.
  """
  @spec list_categories(Scope.t()) :: [String.t()]
  def list_categories(%Scope{user: user}) do
    from(je in JournalEntry,
      where:
        je.user_id == ^user.id and
          not is_nil(je.category) and
          fragment("btrim(?) <> ''", je.category),
      distinct: fragment("lower(btrim(?))", je.category),
      # DISTINCT ON keeps the first row per key, so newest first picks the latest spelling.
      order_by: [desc: je.updated_at, desc: je.id],
      select: fragment("btrim(?)", je.category)
    )
    |> Repo.all()
  end

  @doc """
  Entries approved before booking moved to the invoice page (D17) that still
  need a category and need/want choice, most recently changed first.
  """
  @spec list_unbooked_journal_entries(integer()) :: [JournalEntry.t()]
  def list_unbooked_journal_entries(user_id) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id and je.status == "uncategorized",
      order_by: [desc: je.updated_at, desc: je.id]
    )
    |> Repo.all()
  end

  @doc "Invoice years that have posted entries, newest first."
  @spec posted_journal_entry_years(integer()) :: [integer()]
  def posted_journal_entry_years(user_id) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id and je.status == "posted",
      distinct: true,
      order_by: [desc: fragment("extract(year from ?)::integer", je.date)],
      select: fragment("extract(year from ?)::integer", je.date)
    )
    |> Repo.all()
  end

  @doc """
  One summary per invoice month of `year` that has posted entries, newest
  month first: `%{month: first_day, count: n, totals: [{currency, cents}]}`,
  with currency totals in alphabetical order. `tax_status` keeps only entries
  whose tax claim has that status.
  """
  @spec posted_journal_months(integer(), integer(), String.t() | nil) :: [map()]
  def posted_journal_months(user_id, year, tax_status \\ nil) do
    user_id
    |> posted_entries_query(Date.new!(year, 1, 1), Date.new!(year + 1, 1, 1), tax_status)
    |> group_by([je], [fragment("date_trunc('month', ?)::date", je.date), je.currency])
    |> select([je], %{
      month: fragment("date_trunc('month', ?)::date", je.date),
      currency: je.currency,
      count: count(je.id),
      cents: sum(je.amount_cents)
    })
    |> Repo.all()
    |> Enum.group_by(& &1.month)
    |> Enum.map(fn {month, rows} ->
      rows = Enum.sort_by(rows, & &1.currency)

      %{
        month: month,
        count: Enum.sum_by(rows, & &1.count),
        totals: Enum.map(rows, &{&1.currency, &1.cents})
      }
    end)
    |> Enum.sort_by(& &1.month, {:desc, Date})
  end

  @doc """
  Posted entries with an invoice date in `[from_date, to_date)`, newest invoice
  date first. `tax_status` keeps only entries whose tax claim has that status.
  """
  @spec list_posted_journal_entries(integer(), Date.t(), Date.t(), String.t() | nil) ::
          [JournalEntry.t()]
  def list_posted_journal_entries(
        user_id,
        %Date{} = from_date,
        %Date{} = to_date,
        tax_status \\ nil
      ) do
    user_id
    |> posted_entries_query(from_date, to_date, tax_status)
    |> order_by([je], desc: je.date, desc: je.id)
    |> preload(:tax_deduction_claim)
    |> Repo.all()
  end

  defp posted_entries_query(user_id, from_date, to_date, tax_status) do
    query =
      from(je in JournalEntry,
        where:
          je.user_id == ^user_id and je.status == "posted" and je.date >= ^from_date and
            je.date < ^to_date
      )

    if tax_status do
      from(je in query,
        join: c in assoc(je, :tax_deduction_claim),
        where: c.status == ^tax_status
      )
    else
      query
    end
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

  # The lock makes posting happen once and serializes it with claim revisions,
  # which lock the same row.
  defp fetch_unposted_entry(repo, entry_id) do
    case repo.one!(from je in JournalEntry, where: je.id == ^entry_id, lock: "FOR UPDATE") do
      %JournalEntry{status: "uncategorized"} = entry -> {:ok, entry}
      %JournalEntry{} -> {:error, :already_posted}
    end
  end

  defp fetch_posted_entry(repo, user, entry_id) do
    # Locking the entry serializes revisions even before its claim row exists.
    case repo.one(
           from je in JournalEntry,
             where: je.id == ^entry_id and je.user_id == ^user.id,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      %JournalEntry{status: "posted"} = entry -> {:ok, entry}
      %JournalEntry{} -> {:error, :not_posted}
    end
  end

  defp lock_claim(repo, %JournalEntry{id: entry_id}) do
    {:ok,
     repo.one(
       from c in TaxDeductionClaim, where: c.journal_entry_id == ^entry_id, lock: "FOR UPDATE"
     )}
  end

  # An entry posted before tax claims existed has no claim; the revision creates it.
  defp save_revised_claim(repo, entry, claim, attrs) do
    (claim || TaxDeductionClaim.new_for_entry(entry))
    |> TaxDeductionClaim.changeset_for_revision(tax_revision_attrs(entry, attrs))
    |> validate_revised_amount(entry)
    |> repo.insert_or_update()
  end

  @revision_fields [
    :status,
    :deductible_amount_cents,
    :notes,
    :tax_return_reference,
    :authority_name,
    :authority_reference
  ]

  defp insert_revision_event(repo, user, entry_id, previous, revised) do
    # Saving an unchanged claim (for example a double submit) logs nothing.
    if previous && Map.take(previous, @revision_fields) == Map.take(revised, @revision_fields),
      do: {:ok, nil},
      else: do_insert_revision_event(repo, user, entry_id, previous, revised)
  end

  defp do_insert_revision_event(repo, user, entry_id, previous, revised) do
    EventLog.changeset_for_create(%{
      event_type: "tax_deduction_claim_revised",
      invoice_id: to_string(entry_id),
      user_id: user.id,
      status: "completed",
      metadata: %{
        tax_year: revised.tax_year,
        from_status: previous && previous.status,
        to_status: revised.status,
        from_deductible_amount_cents: previous && previous.deductible_amount_cents,
        to_deductible_amount_cents: revised.deductible_amount_cents,
        reason: revised.notes,
        correction: TaxDeductionClaim.correction?(previous && previous.status, revised.status),
        from_tax_return_reference: previous && previous.tax_return_reference,
        to_tax_return_reference: revised.tax_return_reference,
        from_authority_name: previous && previous.authority_name,
        to_authority_name: revised.authority_name,
        from_authority_reference: previous && previous.authority_reference,
        to_authority_reference: revised.authority_reference
      }
    })
    |> repo.insert()
  end

  # A revised amount lies between 0 and the entry amount: at most the whole
  # invoice is deductible, or taken back for a credit note (a negative amount).
  defp validate_revised_amount(changeset, %JournalEntry{amount_cents: amount}) when amount < 0 do
    Ecto.Changeset.validate_number(changeset, :deductible_amount_cents,
      greater_than_or_equal_to: amount,
      less_than_or_equal_to: 0,
      message: "must be between the credit note amount and 0"
    )
  end

  defp validate_revised_amount(changeset, %JournalEntry{amount_cents: amount}) do
    Ecto.Changeset.validate_number(changeset, :deductible_amount_cents,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: amount,
      message: "must be between 0 and the invoice amount"
    )
  end

  # A reference left out or blank keeps the stored one (a refused claim keeps
  # its return reference); the claim changeset clears those the status drops.
  defp tax_revision_attrs(%JournalEntry{} = entry, attrs) do
    status = attrs["status"]

    references =
      for key <- ~w(tax_return_reference authority_name authority_reference),
          value = blank_to_nil(attrs[key]),
          value != nil,
          into: %{},
          do: {String.to_existing_atom(key), value}

    Map.merge(references, %{
      status: status,
      notes: blank_to_nil(attrs["reason"]),
      deductible_amount_cents:
        TaxDeductionClaim.deductible_amount_cents(
          status,
          attrs["deductible_amount_cents"],
          entry.amount_cents
        )
    })
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

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

    Map.put(
      attrs,
      "deductible_amount_cents",
      TaxDeductionClaim.deductible_amount_cents(
        status,
        attrs["deductible_amount_cents"],
        amount_cents
      )
    )
  end

  @doc """
  Builds the `journal_entry_posted` audit event for a booked `entry`.

  Every way of booking an entry writes this event in the booking's transaction.
  `details` adds path-specific metadata, such as how a backfill chose the values.
  """
  @spec posted_event_changeset(JournalEntry.t(), String.t() | nil, map()) :: Ecto.Changeset.t()
  def posted_event_changeset(%JournalEntry{} = entry, tax_status, details \\ %{}) do
    EventLog.changeset_for_create(%{
      event_type: "journal_entry_posted",
      invoice_id: to_string(entry.id),
      user_id: entry.user_id,
      status: "completed",
      metadata:
        Map.merge(details, %{
          category: entry.category,
          need_or_want: entry.need_or_want,
          tax_deduction_status: tax_status
        })
    })
  end
end
