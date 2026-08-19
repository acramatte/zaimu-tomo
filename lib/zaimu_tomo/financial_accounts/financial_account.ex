defmodule ZaimuTomo.FinancialAccounts.FinancialAccount do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Currency

  schema "financial_accounts" do
    field :name, :string
    field :account_type, Ecto.Enum, values: [:cash, :savings, :investment]
    field :currency, :string
    field :bank_name, :string
    field :account_number, :string
    field :source, Ecto.Enum, values: [:manual, :bank_sync], default: :manual

    # Subtype (e.g. retirement for Swiss 3rd pillar 3a) kept as free-form string
    # to allow extensibility. Liquidity is constrained to a known enum.
    field :subtype, :string
    field :liquidity, Ecto.Enum, values: [:liquid, :restricted, :illiquid]

    field :user_id, :id

    has_many :balance_snapshots, ZaimuTomo.FinancialAccounts.BalanceSnapshot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(financial_account, attrs, user_scope) do
    financial_account
    |> cast(attrs, [:name, :account_type, :currency, :bank_name, :account_number, :source, :subtype, :liquidity])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :account_type, :currency])
    |> update_change(:bank_name, &String.trim/1)
    |> update_change(:account_number, &String.trim/1)
    |> validate_length(:bank_name, max: 255)
    |> validate_length(:account_number, max: 255)
    |> validate_inclusion(:liquidity, [:liquid, :restricted, :illiquid])
    |> put_change(:user_id, user_scope.user.id)
  end
end
