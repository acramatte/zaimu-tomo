defmodule ZaimuTomo.Currency do
  @moduledoc """
  Normalization and shape validation for ISO 4217-style currency codes.

  This validates the three-letter uppercase code shape. It does not maintain
  an allowlist of ISO 4217 codes.
  """

  import Ecto.Changeset

  @currency_format ~r/\A[A-Z]{3}\z/
  @format_error "must be a three-letter ISO 4217 code"

  @doc """
  Trims and uppercases a currency code.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(currency) when is_binary(currency),
    do: currency |> String.trim() |> String.upcase()

  @doc """
  Normalizes a changeset field and validates its three-letter uppercase shape.

  Requiredness remains the responsibility of the owning changeset.
  """
  @spec normalize_and_validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def normalize_and_validate(changeset, field) do
    changeset
    |> update_change(field, &normalize/1)
    |> validate_format(field, @currency_format, message: @format_error)
  end
end
