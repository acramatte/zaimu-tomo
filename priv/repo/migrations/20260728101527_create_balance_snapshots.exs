defmodule ZaimuTomo.Repo.Migrations.CreateBalanceSnapshots do
  use Ecto.Migration

  def change do
    create table(:balance_snapshots) do
      add :amount_cents, :integer, null: false
      add :recorded_on, :date, null: false

      add :financial_account_id, references(:financial_accounts, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:balance_snapshots, [:financial_account_id])
  end
end
