defmodule ZaimuTomo.FinancialAccounts.BalanceSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "balance_snapshots" do
    field :amount_cents, :integer
    field :recorded_on, :date
    belongs_to :financial_account, ZaimuTomo.FinancialAccounts.FinancialAccount

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(balance_snapshot, attrs) do
    balance_snapshot
    |> cast(attrs, [:amount_cents, :recorded_on, :financial_account_id])
    |> validate_required([:amount_cents, :recorded_on, :financial_account_id])
    |> foreign_key_constraint(:financial_account_id)
  end
end
