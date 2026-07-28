defmodule ZaimuTomo.Repo.Migrations.AddBankDetailsToFinancialAccounts do
  use Ecto.Migration

  def change do
    alter table(:financial_accounts) do
      add :bank_name, :string
      add :account_number, :string
    end
  end
end
