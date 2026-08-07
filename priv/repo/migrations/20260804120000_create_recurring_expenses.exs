defmodule ZaimuTomo.Repo.Migrations.CreateRecurringExpenses do
  use Ecto.Migration

  def change do
    create table(:recurring_expenses) do
      add :name, :string, null: false
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :frequency, :string, null: false
      add :start_date, :date, null: false
      add :end_date, :date
      add :user_id, references(:users, type: :id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:recurring_expenses, [:user_id])

    # Reconciliation hook: a journal entry can cover one occurrence of a
    # recurring expense (invoice uploaded after the fact). Deleting the
    # recurring expense keeps the journal entry and just clears the link.
    alter table(:journal_entries) do
      add :recurring_expense_id, references(:recurring_expenses, on_delete: :nilify_all)
    end

    create index(:journal_entries, [:recurring_expense_id])
  end
end
