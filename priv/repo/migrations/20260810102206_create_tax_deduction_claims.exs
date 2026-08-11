defmodule ZaimuTomo.Repo.Migrations.CreateTaxDeductionClaims do
  use Ecto.Migration

  def change do
    create table(:tax_deduction_claims) do
      add :journal_entry_id, references(:journal_entries, on_delete: :nothing), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :tax_year, :integer, null: false
      add :status, :string, null: false, default: "undecided"
      add :category, :string
      add :deductible_amount_cents, :integer, null: false
      add :notes, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tax_deduction_claims, [:journal_entry_id])
    create index(:tax_deduction_claims, [:user_id, :tax_year])
    create index(:tax_deduction_claims, [:status])

    create constraint(:tax_deduction_claims, :tax_deduction_claims_status_check,
             check:
               "status IN ('undecided', 'candidate', 'not_deductible', 'claimed', 'disallowed')"
           )
  end
end
