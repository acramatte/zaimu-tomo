defmodule ZaimuTomo.Repo.Migrations.CreateFinancialAccounts do
  use Ecto.Migration

  def change do
    create table(:financial_accounts) do
      add :name, :string, null: false
      add :account_type, :string, null: false
      add :currency, :string, null: false
      add :source, :string, null: false, default: "manual"
      add :user_id, references(:users, type: :id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:financial_accounts, [:user_id])
  end
end
