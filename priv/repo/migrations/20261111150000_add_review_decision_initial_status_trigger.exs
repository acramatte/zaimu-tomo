defmodule ZaimuTomo.Repo.Migrations.AddReviewDecisionInitialStatusTrigger do
  use Ecto.Migration

  # The other half of `review_decisions_guard_transition`: that trigger guards
  # updates, so a review could still be inserted already decided, skipping the
  # pending state, its lock, and its event log. A review starts as pending or
  # failed for every writer. A check constraint cannot do this because it does
  # not tell an insert from an update. Reported as a check violation named
  # `review_decisions_initial_status_check`.
  #
  # Existing rows are untouched. A full `pg_dump` restore loads rows before it
  # creates triggers; a data-only restore must pass `--disable-triggers`.
  def change do
    execute(
      """
      CREATE FUNCTION review_decisions_guard_initial_status() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'review decision cannot start as %', NEW.review_status
          USING ERRCODE = 'check_violation',
                TABLE = 'review_decisions',
                CONSTRAINT = 'review_decisions_initial_status_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION review_decisions_guard_initial_status()"
    )

    execute(
      """
      CREATE TRIGGER review_decisions_guard_initial_status
      BEFORE INSERT ON review_decisions
      FOR EACH ROW
      WHEN (NEW.review_status NOT IN ('pending', 'failed'))
      EXECUTE FUNCTION review_decisions_guard_initial_status()
      """,
      "DROP TRIGGER review_decisions_guard_initial_status ON review_decisions"
    )
  end
end
