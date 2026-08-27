defmodule ZaimuTomo.Repo.Migrations.AddSubtypeAndLiquidityToFinancialAccounts do
  use Ecto.Migration

  def change do
    alter table(:financial_accounts) do
      add :subtype, :string
      add :liquidity, :string, null: false, default: "liquid"
    end

    create constraint(:financial_accounts, :liquidity_must_be_valid, check: "liquidity IN ('liquid','restricted','illiquid')")
  end
end
