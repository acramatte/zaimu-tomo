defmodule ZaimuTomo.Repo.Migrations.CreateStatements do
  use Ecto.Migration

  def change do
    create table(:statements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :financial_account_id, references(:financial_accounts, on_delete: :restrict),
        null: false

      add :filename, :string, null: false
      add :object_key, :string, null: false
      add :content_sha256, :string, size: 64, null: false
      add :extracted_at, :utc_datetime
      add :account_ref, :string
      add :period_start, :date
      add :period_end, :date
      add :currency, :string, size: 3
      add :opening_balance_cents, :bigint
      add :closing_balance_cents, :bigint
      add :failure_code, :string

      timestamps(type: :utc_datetime)
    end

    create index(:statements, [:user_id])
    create index(:statements, [:financial_account_id])
    create unique_index(:statements, [:object_key])
    create unique_index(:statements, [:user_id, :content_sha256])

    create unique_index(:statements, [:financial_account_id, :period_start, :period_end],
             name: :statements_one_per_account_period,
             where: "period_start IS NOT NULL"
           )

    create constraint(:statements, :statements_extracted_header,
             check: """
             extracted_at IS NULL OR (
               period_start IS NOT NULL AND period_end IS NOT NULL AND currency IS NOT NULL
               AND opening_balance_cents IS NOT NULL AND closing_balance_cents IS NOT NULL
               AND period_start <= period_end
             )
             """
           )

    create table(:statement_lines) do
      add :statement_id, references(:statements, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :booking_date, :date, null: false
      add :value_date, :date
      add :description, :text, null: false
      add :amount_cents, :bigint, null: false
      add :currency, :string, size: 3, null: false
      add :original_amount_cents, :bigint
      add :original_currency, :string, size: 3
    end

    create unique_index(:statement_lines, [:statement_id, :position])
    create index(:statement_lines, [:user_id, :currency, :amount_cents])

    create index(:statement_lines, [:user_id, :original_currency, :original_amount_cents],
             where: "original_currency IS NOT NULL"
           )

    create constraint(:statement_lines, :statement_lines_amount_not_zero,
             check: "amount_cents <> 0"
           )

    create constraint(:statement_lines, :statement_lines_original_amount_pair,
             check: "(original_amount_cents IS NULL) = (original_currency IS NULL)"
           )
  end
end
