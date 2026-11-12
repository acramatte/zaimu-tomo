defmodule ZaimuTomo.Repo.Migrations.AddJournalEntryStatusGuards do
  use Ecto.Migration

  # The journal entry state machine for every writer: an entry starts
  # uncategorized and its only move is to posted, made by
  # `JournalEntry.changeset_for_categorize/2`. Approval with a booking inserts
  # the entry uncategorized and posts it with an update in the same
  # transaction, so no writer inserts a posted entry. The status check
  # validates existing rows, so the migration fails on an unknown status.
  def change do
    create constraint(:journal_entries, :journal_entries_status_check,
             check: "status IN ('uncategorized', 'posted')"
           )

    execute(
      """
      CREATE FUNCTION journal_entries_guard_transition() RETURNS trigger AS $$
      BEGIN
        IF OLD.status = 'uncategorized' AND NEW.status = 'posted' THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'journal entry % cannot move from % to %',
          OLD.id, OLD.status, NEW.status
          USING ERRCODE = 'check_violation',
                TABLE = 'journal_entries',
                CONSTRAINT = 'journal_entries_transition_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION journal_entries_guard_transition()"
    )

    execute(
      """
      CREATE TRIGGER journal_entries_guard_transition
      BEFORE UPDATE ON journal_entries
      FOR EACH ROW
      WHEN (OLD.status IS DISTINCT FROM NEW.status)
      EXECUTE FUNCTION journal_entries_guard_transition()
      """,
      "DROP TRIGGER journal_entries_guard_transition ON journal_entries"
    )

    execute(
      """
      CREATE FUNCTION journal_entries_guard_initial_status() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'journal entry cannot start as %', NEW.status
          USING ERRCODE = 'check_violation',
                TABLE = 'journal_entries',
                CONSTRAINT = 'journal_entries_initial_status_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION journal_entries_guard_initial_status()"
    )

    execute(
      """
      CREATE TRIGGER journal_entries_guard_initial_status
      BEFORE INSERT ON journal_entries
      FOR EACH ROW
      WHEN (NEW.status IS DISTINCT FROM 'uncategorized')
      EXECUTE FUNCTION journal_entries_guard_initial_status()
      """,
      "DROP TRIGGER journal_entries_guard_initial_status ON journal_entries"
    )
  end
end
