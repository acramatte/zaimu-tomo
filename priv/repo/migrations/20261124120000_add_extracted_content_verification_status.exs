defmodule ZaimuTomo.Repo.Migrations.AddExtractedContentVerificationStatus do
  use Ecto.Migration

  # The verifier's result moves from `analysis.verification.status` to a guarded
  # column, because a verified extraction will decide what may post without a
  # human. A success row starts as pending and moves once to one of four end
  # states, through `ExtractedContentContext.record_verification/2`; a failed
  # row has no verification. The check constraint limits the values, and two
  # triggers enforce the start and the single move for every writer.
  #
  # Existing success rows take the status their analysis recorded. A row
  # without a known status becomes verification_failed: a human checks it.
  # Triggers are created after the backfill, so the backfill is not refused. A
  # full `pg_dump` restore loads rows before it creates triggers; a data-only
  # restore must pass `--disable-triggers`.
  @end_states "'verified', 'needs_review', 'rejected', 'verification_failed'"

  def change do
    alter table(:extracted_content) do
      add :verification_status, :string
    end

    execute(
      """
      UPDATE extracted_content
      SET verification_status = CASE
        WHEN analysis -> 'verification' ->> 'status' IN (#{@end_states})
          THEN analysis -> 'verification' ->> 'status'
        ELSE 'verification_failed'
      END
      WHERE status = 'success'
      """,
      # Rolling back drops the column, which is all the backfill wrote.
      "SELECT 1"
    )

    create constraint(:extracted_content, :extracted_content_verification_status_check,
             check: """
             (status = 'success') = (verification_status IS NOT NULL)
             AND (verification_status IS NULL
                  OR verification_status IN ('pending', #{@end_states}))
             """
           )

    execute(
      """
      CREATE FUNCTION extracted_content_guard_verification_initial_status() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'verification cannot start as %', NEW.verification_status
          USING ERRCODE = 'check_violation',
                TABLE = 'extracted_content',
                CONSTRAINT = 'extracted_content_verification_initial_status_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION extracted_content_guard_verification_initial_status()"
    )

    execute(
      """
      CREATE TRIGGER extracted_content_guard_verification_initial_status
      BEFORE INSERT ON extracted_content
      FOR EACH ROW
      WHEN (NEW.verification_status IS NOT NULL AND NEW.verification_status <> 'pending')
      EXECUTE FUNCTION extracted_content_guard_verification_initial_status()
      """,
      "DROP TRIGGER extracted_content_guard_verification_initial_status ON extracted_content"
    )

    execute(
      """
      CREATE FUNCTION extracted_content_guard_verification_transition() RETURNS trigger AS $$
      BEGIN
        IF OLD.verification_status = 'pending'
           AND NEW.verification_status IN (#{@end_states}) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'verification of extraction % cannot move from % to %',
          OLD.id, OLD.verification_status, NEW.verification_status
          USING ERRCODE = 'check_violation',
                TABLE = 'extracted_content',
                CONSTRAINT = 'extracted_content_verification_transition_check';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION extracted_content_guard_verification_transition()"
    )

    execute(
      """
      CREATE TRIGGER extracted_content_guard_verification_transition
      BEFORE UPDATE ON extracted_content
      FOR EACH ROW
      WHEN (OLD.verification_status IS DISTINCT FROM NEW.verification_status)
      EXECUTE FUNCTION extracted_content_guard_verification_transition()
      """,
      "DROP TRIGGER extracted_content_guard_verification_transition ON extracted_content"
    )
  end
end
