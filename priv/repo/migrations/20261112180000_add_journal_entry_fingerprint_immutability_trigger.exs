defmodule ZaimuTomo.Repo.Migrations.AddJournalEntryFingerprintImmutabilityTrigger do
  use Ecto.Migration

  # The fingerprint is a posting-time copy. The only later write is
  # `FingerprintBackfill` filling a missing digest, optionally confirming the
  # reuse in the same update. Reported as a check violation named
  # `journal_entries_fingerprint_immutable_check`, so Ecto reads it as a
  # constraint.
  def change do
    execute(
      """
      CREATE FUNCTION journal_entries_guard_fingerprint() RETURNS trigger AS $$
      BEGIN
        IF OLD.source_document_sha256 IS NULL
           AND NEW.source_document_sha256 IS NOT NULL THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'journal entry % fingerprint cannot change once set', OLD.id
          USING ERRCODE = 'check_violation',
                TABLE = 'journal_entries',
                CONSTRAINT = 'journal_entries_fingerprint_immutable_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION journal_entries_guard_fingerprint()"
    )

    execute(
      """
      CREATE TRIGGER journal_entries_guard_fingerprint
      BEFORE UPDATE ON journal_entries
      FOR EACH ROW
      WHEN (OLD.source_document_sha256 IS DISTINCT FROM NEW.source_document_sha256
            OR OLD.source_file_reuse_confirmed IS DISTINCT FROM NEW.source_file_reuse_confirmed)
      EXECUTE FUNCTION journal_entries_guard_fingerprint()
      """,
      "DROP TRIGGER journal_entries_guard_fingerprint ON journal_entries"
    )
  end
end
