defmodule ZaimuTomo.Repo.Migrations.AddSubtypeAndLiquidityToFinancialAccounts do
  use Ecto.Migration

  def change do
    alter table(:financial_accounts) do
      add :subtype, :string
      add :liquidity, :string
    end

    create index(:financial_accounts, [:subtype])
    create index(:financial_accounts, [:liquidity])
  end
end
