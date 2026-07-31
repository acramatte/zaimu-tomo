defmodule ZaimuTomo.DocumentProcessing.ExtractedDataTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.DocumentProcessing.ExtractedData

  test "normalizes a lowercase currency code" do
    changeset = ExtractedData.changeset(valid_attrs(%{currency: "chf"}))

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :currency) == "CHF"
  end

  test "rejects a currency that is not a three-letter code" do
    changeset = ExtractedData.changeset(valid_attrs(%{currency: "francs"}))

    refute changeset.valid?

    assert {"must be a three-letter ISO 4217 code", [validation: :format]} =
             changeset.errors[:currency]
  end

  test "rejects a currency with a trailing newline" do
    changeset = ExtractedData.changeset(valid_attrs(%{currency: "CHF\n"}))

    refute changeset.valid?
  end

  defp valid_attrs(overrides) do
    Map.merge(
      %{
        amount_to_pay_cents: 1_000,
        invoice_date: "2026-07-31",
        currency: "CHF",
        reason_for_payment: "Test payment",
        issuer: "Test issuer"
      },
      overrides
    )
  end
end
