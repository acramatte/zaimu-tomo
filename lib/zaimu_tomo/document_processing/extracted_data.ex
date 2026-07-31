defmodule ZaimuTomo.DocumentProcessing.ExtractedData do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:amount_to_pay_cents, :integer)
    field(:invoice_date, :string)
    field(:invoice_number, :string)
    field(:currency, :string)
    field(:reason_for_payment, :string)
    field(:issuer, :string)
  end

  @required_fields [:amount_to_pay_cents, :invoice_date, :currency, :reason_for_payment, :issuer]
  @optional_fields [:invoice_number]

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> update_change(:currency, &String.upcase/1)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/,
      message: "must be a three-letter ISO 4217 code"
    )
  end

  def embedded_changeset(_struct, attrs) do
    if is_struct(attrs, __MODULE__) do
      Ecto.Changeset.change(attrs)
    else
      %__MODULE__{}
      |> cast(attrs, @required_fields ++ @optional_fields)
      |> validate_required(@required_fields)
      |> update_change(:currency, &String.upcase/1)
      |> validate_format(:currency, ~r/\A[A-Z]{3}\z/,
        message: "must be a three-letter ISO 4217 code"
      )
    end
  end

  def fields, do: @required_fields ++ @optional_fields
end
