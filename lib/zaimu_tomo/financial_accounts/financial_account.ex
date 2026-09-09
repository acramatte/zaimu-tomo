defmodule ZaimuTomo.FinancialAccounts.FinancialAccount do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Currency

  schema "financial_accounts" do
    field :name, :string
    field :account_type, Ecto.Enum, values: [:cash, :savings, :investment]
    # subtype is optional and currently only :retirement is supported
    field :subtype, Ecto.Enum, values: [:retirement]
    # liquidity indicates how liquid an investment is; allow nil for non-investment accounts
    field :liquidity, Ecto.Enum, values: [:liquid, :restricted, :illiquid]
    field :currency, :string
    field :bank_name, :string
    field :account_number, :string
    field :source, Ecto.Enum, values: [:manual, :bank_sync], default: :manual
    field :user_id, :id

    has_many :balance_snapshots, ZaimuTomo.FinancialAccounts.BalanceSnapshot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(financial_account, attrs, user_scope) do
    # Normalize empty-string optional fields to nil so they persist as nil in the DB
    attrs = normalize_optional_strings(attrs, ["subtype", :subtype, "liquidity", :liquidity])

    financial_account
    |> cast(attrs, [:name, :account_type, :currency, :bank_name, :account_number, :source, :subtype, :liquidity])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :account_type, :currency])
    |> update_change(:bank_name, &String.trim/1)
    |> update_change(:account_number, &String.trim/1)
    |> validate_length(:bank_name, max: 255)
    |> validate_length(:account_number, max: 255)
    |> put_change(:user_id, user_scope.user.id)
  end

  defp normalize_optional_strings(attrs, keys) when is_map(attrs) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, ""} -> Map.put(acc, key, nil)
        _ -> acc
      end
    end)
  end
end
