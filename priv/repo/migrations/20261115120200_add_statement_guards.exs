defmodule ZaimuTomo.Repo.Migrations.AddStatementGuards do
  use Ecto.Migration

  # Database-level invariants for `statements` and `statement_lines` across every
  # writer, including raw SQL: bidirectional extracted header presence, upload
  # identity immutability, monotonic `extracted_at`, initial-state guard,
  # composite foreign keys for tenant and currency consistency, and value checks.
  def up do
    drop constraint(:statements, :statements_extracted_header)

    create constraint(:statements, :statements_extracted_header,
             check: """
             (extracted_at IS NULL
               AND account_ref IS NULL
               AND period_start IS NULL
               AND period_end IS NULL
               AND currency IS NULL
               AND opening_balance_cents IS NULL
               AND closing_balance_cents IS NULL)
             OR (extracted_at IS NOT NULL
               AND period_start IS NOT NULL
               AND period_end IS NOT NULL
               AND currency IS NOT NULL
               AND opening_balance_cents IS NOT NULL
               AND closing_balance_cents IS NOT NULL
               AND period_start <= period_end)
             """
           )

    create constraint(:statements, :statements_failure_code_not_empty,
             check: "failure_code IS NULL OR failure_code <> ''"
           )

    create constraint(:statements, :statements_object_key_prefix,
             check: "object_key LIKE 'statements/%'"
           )

    create constraint(:statements, :statements_content_sha256_format,
             check: "content_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:statements, :statements_currency_format,
             check: "currency IS NULL OR currency ~ '^[A-Z]{3}$'"
           )

    execute("""
    CREATE FUNCTION statements_guard_initial_state() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'statement cannot start with extracted_at or failure_code set'
        USING ERRCODE = 'check_violation',
              TABLE = 'statements',
              CONSTRAINT = 'statements_initial_state_check';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER statements_guard_initial_state
    BEFORE INSERT ON statements
    FOR EACH ROW
    WHEN (NEW.extracted_at IS NOT NULL OR NEW.failure_code IS NOT NULL)
    EXECUTE FUNCTION statements_guard_initial_state()
    """)

    execute("""
    CREATE FUNCTION statements_guard_invariants() RETURNS trigger AS $$
    BEGIN
      IF OLD.user_id IS DISTINCT FROM NEW.user_id
         OR OLD.financial_account_id IS DISTINCT FROM NEW.financial_account_id
         OR OLD.object_key IS DISTINCT FROM NEW.object_key
         OR OLD.content_sha256 IS DISTINCT FROM NEW.content_sha256 THEN
        RAISE EXCEPTION 'statement % upload identity cannot change', OLD.id
          USING ERRCODE = 'check_violation',
                TABLE = 'statements',
                CONSTRAINT = 'statements_upload_immutable_check';
      END IF;

      IF OLD.extracted_at IS NOT NULL AND NEW.extracted_at IS NULL THEN
        RAISE EXCEPTION 'statement % extracted_at cannot be cleared once set', OLD.id
          USING ERRCODE = 'check_violation',
                TABLE = 'statements',
                CONSTRAINT = 'statements_extracted_at_monotonic_check';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER statements_guard_invariants
    BEFORE UPDATE ON statements
    FOR EACH ROW
    EXECUTE FUNCTION statements_guard_invariants()
    """)

    create unique_index(:financial_accounts, [:id, :user_id],
             name: :financial_accounts_id_user_id_index
           )

    execute("ALTER TABLE statements DROP CONSTRAINT statements_financial_account_id_fkey")

    execute("""
    ALTER TABLE statements
      ADD CONSTRAINT statements_financial_account_id_fkey
      FOREIGN KEY (financial_account_id, user_id)
      REFERENCES financial_accounts (id, user_id)
      ON DELETE RESTRICT
    """)

    create unique_index(:statements, [:id, :user_id, :currency],
             name: :statements_id_user_id_currency_index
           )

    execute("ALTER TABLE statement_lines DROP CONSTRAINT statement_lines_statement_id_fkey")

    execute("""
    ALTER TABLE statement_lines
      ADD CONSTRAINT statement_lines_statement_id_fkey
      FOREIGN KEY (statement_id, user_id, currency)
      REFERENCES statements (id, user_id, currency)
      ON DELETE CASCADE
    """)

    create constraint(:statement_lines, :statement_lines_position_positive,
             check: "position >= 1"
           )

    create constraint(:statement_lines, :statement_lines_original_amount_not_zero,
             check: "original_amount_cents IS NULL OR original_amount_cents <> 0"
           )

    create constraint(:statement_lines, :statement_lines_original_amount_same_sign,
             check:
               "original_amount_cents IS NULL OR (original_amount_cents > 0) = (amount_cents > 0)"
           )

    create constraint(:statement_lines, :statement_lines_currency_format,
             check: "currency ~ '^[A-Z]{3}$'"
           )

    create constraint(:statement_lines, :statement_lines_original_currency_format,
             check: "original_currency IS NULL OR original_currency ~ '^[A-Z]{3}$'"
           )
  end

  def down do
    drop constraint(:statement_lines, :statement_lines_original_currency_format)
    drop constraint(:statement_lines, :statement_lines_currency_format)
    drop constraint(:statement_lines, :statement_lines_original_amount_same_sign)
    drop constraint(:statement_lines, :statement_lines_original_amount_not_zero)
    drop constraint(:statement_lines, :statement_lines_position_positive)

    execute("ALTER TABLE statement_lines DROP CONSTRAINT statement_lines_statement_id_fkey")

    execute("""
    ALTER TABLE statement_lines
      ADD CONSTRAINT statement_lines_statement_id_fkey
      FOREIGN KEY (statement_id)
      REFERENCES statements (id)
      ON DELETE CASCADE
    """)

    drop unique_index(:statements, [:id, :user_id, :currency],
           name: :statements_id_user_id_currency_index
         )

    execute("ALTER TABLE statements DROP CONSTRAINT statements_financial_account_id_fkey")

    execute("""
    ALTER TABLE statements
      ADD CONSTRAINT statements_financial_account_id_fkey
      FOREIGN KEY (financial_account_id)
      REFERENCES financial_accounts (id)
      ON DELETE RESTRICT
    """)

    drop unique_index(:financial_accounts, [:id, :user_id],
           name: :financial_accounts_id_user_id_index
         )

    execute("DROP TRIGGER statements_guard_invariants ON statements")
    execute("DROP FUNCTION statements_guard_invariants()")

    execute("DROP TRIGGER statements_guard_initial_state ON statements")
    execute("DROP FUNCTION statements_guard_initial_state()")

    drop constraint(:statements, :statements_currency_format)
    drop constraint(:statements, :statements_content_sha256_format)
    drop constraint(:statements, :statements_object_key_prefix)
    drop constraint(:statements, :statements_failure_code_not_empty)

    drop constraint(:statements, :statements_extracted_header)

    create constraint(:statements, :statements_extracted_header,
             check: """
             extracted_at IS NULL OR (
               period_start IS NOT NULL AND period_end IS NOT NULL AND currency IS NOT NULL
               AND opening_balance_cents IS NOT NULL AND closing_balance_cents IS NOT NULL
               AND period_start <= period_end
             )
             """
           )
  end
end
