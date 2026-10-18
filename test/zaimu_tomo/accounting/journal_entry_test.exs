defmodule ZaimuTomo.Accounting.JournalEntryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Currency

  test "normalizes a lowercase currency code" do
    changeset = JournalEntry.changeset_for_create(valid_attrs(%{currency: "usd"}))

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :currency) == "USD"
  end

  test "rejects a currency that is not a three-letter code" do
    changeset = JournalEntry.changeset_for_create(valid_attrs(%{currency: "US"}))

    refute changeset.valid?

    assert {"must be a three-letter ISO 4217 code", [validation: :format]} =
             changeset.errors[:currency]
  end

  test "trims and normalizes a currency code" do
    changeset = JournalEntry.changeset_for_create(valid_attrs(%{currency: " USD\n"}))

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :currency) == "USD"
  end

  property "changeset_for_create/1 is valid exactly when every required field is present and currency is a well-formed code" do
    check all(
            currency <- currency_like_generator(),
            has_decision? <- StreamData.boolean(),
            has_user? <- StreamData.boolean(),
            has_amount? <- StreamData.boolean(),
            has_date? <- StreamData.boolean()
          ) do
      attrs =
        %{currency: currency}
        |> put_if(has_decision?, :review_decision_id, 1)
        |> put_if(has_user?, :user_id, 1)
        |> put_if(has_amount?, :amount_cents, 1_000)
        |> put_if(has_date?, :date, ~D[2026-07-31])

      changeset = JournalEntry.changeset_for_create(attrs)

      currency_ok? = Currency.normalize(currency) =~ ~r/\A[A-Z]{3}\z/
      all_required_present? = has_decision? and has_user? and has_amount? and has_date?

      assert changeset.valid? == (currency_ok? and all_required_present?)
    end
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
        review_decision_id: 1,
        user_id: 1,
        amount_cents: 1_000,
        currency: "USD",
        date: ~D[2026-07-31],
        status: "uncategorized"
      },
      overrides
    )
  end
end
