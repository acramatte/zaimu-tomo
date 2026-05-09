defmodule ZaimuTomo.Repo.Migrations.CreateJournalEntries do
  use Ecto.Migration

  def change do
    create table(:journal_entries) do
      add :review_decision_id, references(:review_decisions, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :date, :date
      add :description, :string
      add :issuer, :string
      add :invoice_number, :string
      add :category, :string
      add :status, :string, null: false, default: "uncategorized"
      add :notes, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:journal_entries, [:review_decision_id])
    create index(:journal_entries, [:user_id])
    create index(:journal_entries, [:status])
    create index(:journal_entries, [:date])
  end
end
