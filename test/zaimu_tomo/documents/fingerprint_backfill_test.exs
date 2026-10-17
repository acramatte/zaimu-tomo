defmodule ZaimuTomo.Documents.FingerprintBackfillTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures, only: [extracted_content_fixture: 3]

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Documents.FingerprintBackfill
  alias ZaimuTomo.Review
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  # Independently computed with `printf '…' | sha256sum`.
  @old_bytes_sha256 "b4dddecf813201f4a83f2ae71f6fa1a03ea961c3738e3da7fff94859c5ad1c17"
  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  defmodule FailingStorage do
    @moduledoc false
    @behaviour ZaimuTomo.Storage.Adapter

    alias ZaimuTomo.Storage.Memory

    @impl true
    def read_object("documents/broken" <> _, _config), do: {:error, :timeout}
    def read_object(key, config), do: Memory.read_object(key, config)

    @impl true
    defdelegate put_object(key, body, config), to: Memory
    @impl true
    defdelegate get_object(key, destination, config), to: Memory
    @impl true
    defdelegate delete_object(key, config), to: Memory
    @impl true
    defdelegate head_object(key, config), to: Memory
  end

  setup do
    Memory.reset()
    storage = Application.fetch_env!(:zaimu_tomo, :storage)

    on_exit(fn ->
      Application.put_env(:zaimu_tomo, :storage, storage)
      Memory.reset()
    end)

    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user)}
  end

  test "hashes stored objects, propagates to posted entries, and is repeatable", %{
    scope: scope,
    user: user
  } do
    {document, entry} = legacy_posting(scope, user, "documents/old.pdf", "old bytes", "Issuer 1")
    assert document.content_sha256 == nil
    assert entry.source_document_sha256 == nil

    current =
      document_fixture(scope, %{object_key: "documents/new.pdf", content_sha256: @abc_sha256})

    last_edit = ~U[2026-03-02 08:00:00Z]

    Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
      set: [updated_at: last_edit]
    )

    assert {:ok, summary} = FingerprintBackfill.run()
    assert summary.documents_hashed == 1
    assert summary.documents_already_complete == 1
    assert summary.entries_updated == 1
    assert summary.entries_already_complete == 0

    assert Repo.reload!(document).content_sha256 == @old_bytes_sha256
    assert Repo.reload!(current).content_sha256 == @abc_sha256
    reloaded = Repo.reload!(entry)
    assert reloaded.source_document_sha256 == @old_bytes_sha256
    refute reloaded.source_file_reuse_confirmed
    # Derived metadata: the entry keeps its place in the journal list.
    assert reloaded.updated_at == last_edit

    assert {:ok, again} = FingerprintBackfill.run()
    assert again.documents_hashed == 0
    assert again.documents_already_complete == 2
    assert again.entries_updated == 0
    assert again.entries_already_complete == 1
    assert FingerprintBackfill.format_summary(again) =~ "coverage is complete"
  end

  test "reports a missing object, leaves it null, and reports incomplete coverage", %{
    scope: scope,
    user: user
  } do
    {document, entry} = legacy_posting(scope, user, "documents/gone.pdf", nil, "Issuer 1")

    assert {:error, summary} = FingerprintBackfill.run()
    assert summary.missing_objects == [document.id]
    assert summary.entries_source_unavailable == [entry.id]
    assert Repo.reload!(document).content_sha256 == nil
    assert Repo.reload!(entry).source_document_sha256 == nil

    report = FingerprintBackfill.format_summary(summary)
    assert report =~ "Missing object for document #{document.id}"
    assert report =~ "INCOMPLETE"
  end

  test "reports a storage read failure and leaves the digest null", %{scope: scope} do
    Application.put_env(:zaimu_tomo, :storage, adapter: FailingStorage)
    document = document_fixture(scope, %{object_key: "documents/broken.pdf"})
    {:ok, _} = Storage.put_object(document.object_key, "bytes")

    assert {:error, summary} = FingerprintBackfill.run()
    assert summary.read_failures == [%{document_id: document.id, reason: :timeout}]
    assert summary.documents_hashed == 0
    assert Repo.reload!(document).content_sha256 == nil

    assert FingerprintBackfill.format_summary(summary) =~
             "Read failure for document #{document.id}"
  end

  test "a same-user historical collision is reported and leaves both entries intact", %{
    scope: scope,
    user: user
  } do
    {_doc_a, first} = legacy_posting(scope, user, "documents/a.pdf", "old bytes", "Issuer A")
    {_doc_b, later} = legacy_posting(scope, user, "documents/b.pdf", "old bytes", "Issuer B")

    # Another user's identical bytes are not a collision.
    other = user_fixture()

    {_doc_c, theirs} =
      legacy_posting(user_scope_fixture(other), other, "documents/c.pdf", "old bytes", "Issuer A")

    assert {:error, summary} = FingerprintBackfill.run()
    assert summary.entries_updated == 2

    assert summary.collisions == [
             %{journal_entry_id: later.id, user_id: user.id, conflicts_with: first.id}
           ]

    assert Repo.reload!(first).source_document_sha256 == @old_bytes_sha256
    assert Repo.reload!(theirs).source_document_sha256 == @old_bytes_sha256
    later_reloaded = Repo.reload!(later)
    assert later_reloaded.source_document_sha256 == nil
    refute later_reloaded.source_file_reuse_confirmed
    assert Repo.aggregate(from(je in JournalEntry, where: je.user_id == ^user.id), :count) == 2

    report = FingerprintBackfill.format_summary(summary)
    assert report =~ "Collision: journal entry #{later.id} (user #{user.id})"
    assert report =~ "entry #{first.id}"
    refute report =~ @old_bytes_sha256

    # Rerunning without a human decision reports the same collision again.
    assert {:error, %{collisions: [%{journal_entry_id: id}]}} = FingerprintBackfill.run()
    assert id == later.id
  end

  test "a human-confirmed reuse resolves the collision in one update", %{
    scope: scope,
    user: user
  } do
    {_doc_a, first} = legacy_posting(scope, user, "documents/a.pdf", "old bytes", "Issuer A")
    {_doc_b, later} = legacy_posting(scope, user, "documents/b.pdf", "old bytes", "Issuer B")
    {_doc_d, unrelated} = legacy_posting(scope, user, "documents/d.pdf", "abc", "Issuer D")

    assert {:error, _summary} = FingerprintBackfill.run()

    # Confirming an entry that does not collide is reported, not applied.
    assert {:ok, summary} = FingerprintBackfill.run(confirm_reuse: [later.id, unrelated.id])
    assert summary.entries_reuse_confirmed == [later.id]
    assert summary.collisions == []
    assert summary.unused_reuse_confirmations == [unrelated.id]

    assert %{source_document_sha256: @old_bytes_sha256, source_file_reuse_confirmed: true} =
             Repo.reload!(later)

    assert %{source_file_reuse_confirmed: false} = Repo.reload!(first)

    assert %{source_document_sha256: @abc_sha256, source_file_reuse_confirmed: false} =
             Repo.reload!(unrelated)
  end

  test "a confirmation is applied only to an entry that actually collides", %{
    scope: scope,
    user: user
  } do
    {_doc, only} = legacy_posting(scope, user, "documents/a.pdf", "old bytes", "Issuer A")

    assert {:ok, summary} = FingerprintBackfill.run(confirm_reuse: [only.id])
    assert summary.entries_reuse_confirmed == []
    assert summary.unused_reuse_confirmations == [only.id]
    refute Repo.reload!(only).source_file_reuse_confirmed
  end

  # A posting made before fingerprints existed: the document has no digest,
  # so the entry is posted with none.
  defp legacy_posting(scope, user, object_key, bytes, issuer) do
    if bytes, do: {:ok, ^object_key} = Storage.put_object(object_key, bytes)

    document = document_fixture(scope, %{object_key: object_key})

    content =
      extracted_content_fixture(document, user, %{
        extracted_data: %{
          amount_to_pay_cents: 4200,
          invoice_date: "2026-03-01",
          invoice_number: nil,
          currency: "CHF",
          reason_for_payment: "Legacy",
          issuer: issuer
        }
      })

    {:ok, _} = Review.create_initial_decision(content)
    {:ok, decision} = Review.approve_invoice(content.id, user.id)
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)

    {Repo.get!(Document, document.id), Repo.get!(JournalEntry, entry.id)}
  end
end
