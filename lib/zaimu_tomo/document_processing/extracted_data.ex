defmodule ZaimuTomo.DocumentProcessing.ExtractedData do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Currency

  @primary_key false
  embedded_schema do
    field(:amount_to_pay_cents, :integer)
    field(:invoice_date, :string)
    field(:invoice_number, :string)
    field(:currency, :string)
    field(:reason_for_payment, :string)
    field(:issuer, :string)
  end

  @type t :: %__MODULE__{}

  @required_fields [:amount_to_pay_cents, :invoice_date, :currency, :reason_for_payment, :issuer]
  @optional_fields [:invoice_number]

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> Currency.normalize_and_validate(:currency)
    |> validate_required(@required_fields)
  end

  def embedded_changeset(_struct, attrs) do
    if is_struct(attrs, __MODULE__) do
      Ecto.Changeset.change(attrs)
    else
      %__MODULE__{}
      |> cast(attrs, @required_fields ++ @optional_fields)
      |> Currency.normalize_and_validate(:currency)
      |> validate_required(@required_fields)
    end
  end

  def fields, do: @required_fields ++ @optional_fields

  @doc """
  Lists the fields whose value differs between `from` and `to` as
  `{field, from_value, to_value}`, in `fields/0` order. Surrounding whitespace
  is not a difference.
  """
  @spec changes(t(), t()) :: [{atom(), term(), term()}]
  def changes(%__MODULE__{} = from, %__MODULE__{} = to) do
    for field <- fields(),
        comparable(Map.get(from, field)) != comparable(Map.get(to, field)),
        do: {field, Map.get(from, field), Map.get(to, field)}
  end

  defp comparable(value) when is_binary(value), do: String.trim(value)
  defp comparable(value), do: value
end
