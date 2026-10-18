defmodule ZaimuTomo.DocumentProcessing.ExtractedDataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.Currency
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

  test "trims and normalizes a currency code" do
    changeset = ExtractedData.changeset(valid_attrs(%{currency: " CHF\n"}))

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :currency) == "CHF"
  end

  property "changeset/1 is valid exactly when every required field is present and currency is a well-formed code" do
    check all(
            currency <- currency_like_generator(),
            has_amount? <- StreamData.boolean(),
            has_date? <- StreamData.boolean(),
            has_reason? <- StreamData.boolean(),
            has_issuer? <- StreamData.boolean()
          ) do
      attrs =
        %{currency: currency}
        |> put_if(has_amount?, :amount_to_pay_cents, 1_000)
        |> put_if(has_date?, :invoice_date, "2026-07-31")
        |> put_if(has_reason?, :reason_for_payment, "Test payment")
        |> put_if(has_issuer?, :issuer, "Test issuer")

      changeset = ExtractedData.changeset(attrs)

      currency_ok? = Currency.normalize(currency) =~ ~r/\A[A-Z]{3}\z/
      all_required_present? = has_amount? and has_date? and has_reason? and has_issuer?

      assert changeset.valid? == (currency_ok? and all_required_present?)
    end
  end

  property "changeset/1 never raises on malformed LLM-shaped output" do
    check all(attrs <- malformed_extracted_data_generator()) do
      changeset = ExtractedData.changeset(attrs)
      assert %Ecto.Changeset{} = changeset
    end
  end

  defp garbage_value_generator do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.boolean(),
      StreamData.integer(),
      StreamData.float(),
      StreamData.string(:printable, max_length: 10),
      StreamData.list_of(StreamData.integer(), max_length: 3),
      StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer(), max_length: 2)
    ])
  end

  defp malformed_extracted_data_generator do
    StreamData.fixed_map(
      Map.new(ExtractedData.fields(), fn field -> {field, garbage_value_generator()} end)
    )
  end

  defp currency_like_generator do
    gen all(
          core <- StreamData.string(:alphanumeric, max_length: 6),
          leading <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 2),
          trailing <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 2)
        ) do
      leading <> core <> trailing
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

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
