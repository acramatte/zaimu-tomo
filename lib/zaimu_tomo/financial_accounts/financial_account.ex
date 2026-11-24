defmodule ZaimuTomo.FinancialAccounts.FinancialAccount do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Currency

  @account_types [:current, :savings, :cash, :investment, :credit_card]

  @type account_type :: :current | :savings | :cash | :investment | :credit_card
  @type t :: %__MODULE__{}

  schema "financial_accounts" do
    field :name, :string
    field :account_type, Ecto.Enum, values: @account_types
    field :currency, :string
    field :bank_name, :string
    field :account_number, :string
    field :source, Ecto.Enum, values: [:manual, :bank_sync], default: :manual
    field :user_id, :id

    has_many :balance_snapshots, ZaimuTomo.FinancialAccounts.BalanceSnapshot

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the valid financial account types."
  @spec account_types() :: [account_type()]
  def account_types, do: @account_types

  @doc "Returns the human-readable account type label for prompts."
  @spec type_label(account_type()) :: String.t()
  def type_label(type) when type in @account_types do
    type |> Atom.to_string() |> String.replace("_", " ")
  end

  @doc false
  def changeset(financial_account, attrs, user_scope) do
    financial_account
    |> cast(attrs, [:name, :account_type, :currency, :bank_name, :account_number, :source])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :account_type, :currency])
    |> update_change(:bank_name, &String.trim/1)
    |> update_change(:account_number, &String.trim/1)
    |> validate_length(:bank_name, max: 255)
    |> validate_length(:account_number, max: 255)
    |> put_change(:user_id, user_scope.user.id)
  end

  @doc """
  Changeset for deleting an account. Its statements keep it
  (`on_delete: :restrict`), so deleting an account that still has statements
  returns an error on `:statements` instead of raising.
  """
  def delete_changeset(financial_account) do
    financial_account
    |> change()
    |> foreign_key_constraint(:statements,
      name: :statements_financial_account_id_fkey,
      message: "has statements; delete its statements first"
    )
  end
end
