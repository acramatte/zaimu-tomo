defmodule ZaimuTomo.Repo.Migrations.AddReviewDecisionTransitionTrigger do
  use Ecto.Migration

  # The transition rule of `ReviewDecision.decide_changeset/3`, enforced for
  # every writer: a status only moves from pending to approved, amended, or
  # rejected. A check constraint cannot do this because it does not see the
  # previous status. Reported as a check violation named
  # `review_decisions_transition_check`, so Ecto reads it as a constraint.
  def change do
    execute(
      """
      CREATE FUNCTION review_decisions_guard_transition() RETURNS trigger AS $$
      BEGIN
        IF OLD.review_status = 'pending'
           AND NEW.review_status IN ('approved', 'amended', 'rejected') THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'review decision % cannot move from % to %',
          OLD.id, OLD.review_status, NEW.review_status
          USING ERRCODE = 'check_violation',
                TABLE = 'review_decisions',
                CONSTRAINT = 'review_decisions_transition_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION review_decisions_guard_transition()"
    )

    execute(
      """
      CREATE TRIGGER review_decisions_guard_transition
      BEFORE UPDATE ON review_decisions
      FOR EACH ROW
      WHEN (OLD.review_status IS DISTINCT FROM NEW.review_status)
      EXECUTE FUNCTION review_decisions_guard_transition()
      """,
      "DROP TRIGGER review_decisions_guard_transition ON review_decisions"
    )
  end
end
