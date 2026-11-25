defmodule ZaimuTomo.Repo.Migrations.AddJournalEntriesAmountKeyIndex do
  use Ecto.Migration

  def change do
    create index(:journal_entries, [:user_id, :currency, :amount_cents],
             where: "status = 'posted' AND date IS NOT NULL"
           )
  end
end
