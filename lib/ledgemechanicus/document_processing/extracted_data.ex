defmodule Ledgemechanicus.DocumentProcessing.ExtractedData do
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

  @doc """
  Builds a changeset from a plain map
  All fields are required here.
  """
  def changeset(attrs) do
    %Ledgemechanicus.DocumentProcessing.ExtractedData{}
    |> cast(attrs, [
      :amount_to_pay_cents,
      :invoice_date,
      :invoice_number,
      :currency,
      :reason_for_payment,
      :issuer
    ])
    |> validate_required([
      :amount_to_pay_cents,
      :invoice_date,
      :invoice_number,
      :currency,
      :reason_for_payment,
      :issuer
    ])
  end
end
