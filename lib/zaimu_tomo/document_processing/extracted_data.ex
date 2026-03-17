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

  @doc """
  Builds a changeset from a plain map
  All fields are required here.
  """
  # Standalone changeset: Takes a map, creates a new struct
  # Used in DocumentOCR.process flow
  def changeset(attrs) when is_map(attrs) do
    %ZaimuTomo.DocumentProcessing.ExtractedData{}
    |> cast(attrs, fields())
    |> validate_required(fields())
  end

  # Embedded changeset: Takes a struct and attrs, used by cast_embed
  # Used in ExtractedContent.changeset
  def embedded_changeset(_struct, attrs) do
    # If attrs is already a validated struct, just wrap it in a changeset
    if is_struct(attrs, __MODULE__) do
      Ecto.Changeset.change(attrs)
    else
      %__MODULE__{}
      |> cast(attrs, fields())
      |> validate_required(fields())
    end
  end

  defp fields do
    [:amount_to_pay_cents, :invoice_date, :invoice_number, :currency, :reason_for_payment, :issuer]
  end
end
