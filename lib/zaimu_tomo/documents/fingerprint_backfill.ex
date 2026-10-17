defmodule ZaimuTomo.Documents.FingerprintBackfill do
  @moduledoc """
  Idempotent, online backfill of exact-byte fingerprints for rows created
  before fingerprints existed.

  1. Every document with a null `content_sha256` is read through
     `ZaimuTomo.Storage` and hashed. A missing or unreadable object is
     reported and left null; no other value is ever stored in its place.
  2. Every journal entry with a null `source_document_sha256` receives its
     source document's fingerprint, one entry per update and oldest first, so
     the first posting of a file keeps it. A unique-index violation (a same-user
     historical duplicate) affects only that row: it is reported with the entry
     it collides with and left null. Ledger rows are never deleted or merged.

  A human may resolve a reported collision by listing the later entry in
  `:confirm_reuse`; the backfill then sets its digest and
  `source_file_reuse_confirmed` in one update. This is the only permitted
  update of an existing entry's fingerprint (spec D7), so it must run before
  any database-level immutability trigger on `journal_entries` exists, or that
  trigger must allow it.

  The report contains row IDs and counts only, never bytes or digests. The
  partial unique index already exists, so concurrent postings cannot create a
  same-user duplicate while this runs.
  """

  import Ecto.Query, warn: false

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Documents.Fingerprint
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Storage

  @type collision :: %{journal_entry_id: integer(), user_id: integer(), conflicts_with: integer()}

  @type summary :: %{
          documents_hashed: non_neg_integer(),
          documents_already_complete: non_neg_integer(),
          missing_objects: [integer()],
          read_failures: [%{document_id: integer(), reason: term()}],
          entries_updated: non_neg_integer(),
          entries_already_complete: non_neg_integer(),
          entries_reuse_confirmed: [integer()],
          entries_source_unavailable: [integer()],
          collisions: [collision()],
          unused_reuse_confirmations: [integer()]
        }

  @doc """
  Runs the backfill.

  Returns `{:ok, summary}` when historical coverage is complete, and
  `{:error, summary}` when any object is missing or unreadable, an entry's
  source fingerprint is unavailable, or a collision awaits human review.

  Options:

    * `:confirm_reuse` — journal entry IDs a human confirmed as legitimate
      reuses of an already posted file. Applied only to an entry whose plain
      update collides; otherwise reported as unused.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, summary()}
  def run(opts \\ []) do
    confirm_reuse = opts |> Keyword.get(:confirm_reuse, []) |> MapSet.new()

    summary =
      empty_summary()
      |> backfill_documents()
      |> backfill_journal_entries(confirm_reuse)
      |> finalize(confirm_reuse)

    if complete?(summary), do: {:ok, summary}, else: {:error, summary}
  end

  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    [
      "Fingerprint backfill summary: " <>
        "documents_hashed=#{summary.documents_hashed} " <>
        "documents_already_complete=#{summary.documents_already_complete} " <>
        "missing_objects=#{length(summary.missing_objects)} " <>
        "read_failures=#{length(summary.read_failures)} " <>
        "entries_updated=#{summary.entries_updated} " <>
        "entries_already_complete=#{summary.entries_already_complete} " <>
        "entries_reuse_confirmed=#{length(summary.entries_reuse_confirmed)} " <>
        "entries_source_unavailable=#{length(summary.entries_source_unavailable)} " <>
        "collisions=#{length(summary.collisions)}"
      | Enum.map(summary.missing_objects, &"Missing object for document #{&1}") ++
          Enum.map(summary.read_failures, &format_read_failure/1) ++
          Enum.map(summary.entries_source_unavailable, &format_source_unavailable/1) ++
          Enum.map(summary.collisions, &format_collision/1) ++
          Enum.map(summary.entries_reuse_confirmed, &"Confirmed reuse for journal entry #{&1}") ++
          Enum.map(summary.unused_reuse_confirmations, &format_unused_confirmation/1) ++
          coverage_line(summary)
    ]
    |> Enum.join("\n")
  end

  # -- Documents ---------------------------------------------------------------

  defp backfill_documents(summary) do
    already_complete =
      Repo.aggregate(from(d in Document, where: not is_nil(d.content_sha256)), :count)

    from(d in Document,
      where: is_nil(d.content_sha256),
      order_by: [asc: d.id],
      select: {d.id, d.object_key}
    )
    |> Repo.all()
    |> Enum.reduce(%{summary | documents_already_complete: already_complete}, &hash_document/2)
  end

  defp hash_document({document_id, object_key}, summary) do
    case Storage.read_object(object_key) do
      {:ok, body} ->
        # Conditional on the same key and a still-null digest, so a concurrent
        # file replacement (which records its own digest) is never overwritten.
        {count, _} =
          from(d in Document,
            where:
              d.id == ^document_id and d.object_key == ^object_key and
                is_nil(d.content_sha256)
          )
          |> Repo.update_all(set: [content_sha256: Fingerprint.sha256(body)])

        if count == 1,
          do: %{summary | documents_hashed: summary.documents_hashed + 1},
          else: %{summary | documents_already_complete: summary.documents_already_complete + 1}

      {:error, :not_found} ->
        %{summary | missing_objects: [document_id | summary.missing_objects]}

      {:error, reason} ->
        failure = %{document_id: document_id, reason: reason}
        %{summary | read_failures: [failure | summary.read_failures]}
    end
  end

  # -- Journal entries ---------------------------------------------------------

  defp backfill_journal_entries(summary, confirm_reuse) do
    already_complete =
      Repo.aggregate(
        from(je in JournalEntry, where: not is_nil(je.source_document_sha256)),
        :count
      )

    from(je in JournalEntry,
      left_join: rd in ReviewDecision,
      on: rd.id == je.review_decision_id,
      left_join: ec in ExtractedContent,
      on: ec.id == rd.extracted_content_id and ec.user_id == je.user_id,
      left_join: d in Document,
      on: d.id == ec.document_id and d.user_id == je.user_id,
      where: is_nil(je.source_document_sha256),
      order_by: [asc: je.inserted_at, asc: je.id],
      select: {je, d.content_sha256}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{summary | entries_already_complete: already_complete},
      &backfill_entry(&1, &2, confirm_reuse)
    )
  end

  defp backfill_entry({entry, nil}, summary, _confirm_reuse) do
    %{summary | entries_source_unavailable: [entry.id | summary.entries_source_unavailable]}
  end

  defp backfill_entry({entry, digest}, summary, confirm_reuse) do
    case update_entry(entry, %{source_document_sha256: digest}) do
      {:ok, _entry} ->
        %{summary | entries_updated: summary.entries_updated + 1}

      {:error, :collision} ->
        if MapSet.member?(confirm_reuse, entry.id) do
          confirm_reuse(entry, digest, summary)
        else
          collision = %{
            journal_entry_id: entry.id,
            user_id: entry.user_id,
            conflicts_with: conflicting_entry_id(entry.user_id, digest)
          }

          %{summary | collisions: [collision | summary.collisions]}
        end
    end
  end

  defp confirm_reuse(entry, digest, summary) do
    attrs = %{source_document_sha256: digest, source_file_reuse_confirmed: true}

    # A confirmed reuse is outside the partial index, so it cannot collide.
    {:ok, _entry} = update_entry(entry, attrs)
    %{summary | entries_reuse_confirmed: [entry.id | summary.entries_reuse_confirmed]}
  end

  # The fingerprint is derived metadata, not an edit: keep `updated_at`, which
  # orders the user's journal list.
  defp update_entry(entry, attrs) do
    entry
    |> JournalEntry.changeset_for_fingerprint_backfill(attrs)
    |> Ecto.Changeset.force_change(:updated_at, entry.updated_at)
    |> Repo.update()
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      {:error, %Ecto.Changeset{} = changeset} ->
        if source_file_collision?(changeset),
          do: {:error, :collision},
          else: raise(Ecto.InvalidChangesetError, action: :update, changeset: changeset)
    end
  end

  defp source_file_collision?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] == JournalEntry.duplicate_source_file_index()
    end)
  end

  defp conflicting_entry_id(user_id, digest) do
    from(je in JournalEntry,
      where: je.user_id == ^user_id and je.source_document_sha256 == ^digest,
      where: not je.source_file_reuse_confirmed,
      select: je.id,
      limit: 1
    )
    |> Repo.one()
  end

  # -- Summary -----------------------------------------------------------------

  defp empty_summary do
    %{
      documents_hashed: 0,
      documents_already_complete: 0,
      missing_objects: [],
      read_failures: [],
      entries_updated: 0,
      entries_already_complete: 0,
      entries_reuse_confirmed: [],
      entries_source_unavailable: [],
      collisions: [],
      unused_reuse_confirmations: []
    }
  end

  defp finalize(summary, confirm_reuse) do
    applied = MapSet.new(summary.entries_reuse_confirmed)

    %{
      summary
      | missing_objects: Enum.reverse(summary.missing_objects),
        read_failures: Enum.reverse(summary.read_failures),
        entries_reuse_confirmed: Enum.reverse(summary.entries_reuse_confirmed),
        entries_source_unavailable: Enum.reverse(summary.entries_source_unavailable),
        collisions: Enum.reverse(summary.collisions),
        unused_reuse_confirmations: confirm_reuse |> MapSet.difference(applied) |> Enum.sort()
    }
  end

  defp complete?(summary) do
    summary.missing_objects == [] and summary.read_failures == [] and
      summary.entries_source_unavailable == [] and summary.collisions == []
  end

  defp coverage_line(summary) do
    if complete?(summary),
      do: ["Historical fingerprint coverage is complete."],
      else: ["Historical fingerprint coverage is INCOMPLETE; see the rows above."]
  end

  defp format_read_failure(%{document_id: id, reason: reason}),
    do: "Read failure for document #{id}: #{inspect(reason)}"

  defp format_source_unavailable(id),
    do: "Journal entry #{id}: source document fingerprint unavailable"

  defp format_collision(%{journal_entry_id: id, user_id: user_id, conflicts_with: other}),
    do:
      "Collision: journal entry #{id} (user #{user_id}) has the same source file as " <>
        "entry #{other}; left null for human ledger review"

  defp format_unused_confirmation(id),
    do: "Reuse confirmation for journal entry #{id} not applied (no collision to resolve)"
end
