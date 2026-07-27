defmodule ZaimuTomo.Repo.Migrations.AddNeedOrWantToJournalEntries do
  use Ecto.Migration

  def change do
    alter table(:journal_entries) do
      add :need_or_want, :string
    end

    create constraint(:journal_entries, :journal_entries_need_or_want_check,
             check: "need_or_want IS NULL OR need_or_want IN ('need', 'want')"
           )

    create index(:journal_entries, [:need_or_want])
  end
end
