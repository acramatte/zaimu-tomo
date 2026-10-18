defmodule ZaimuTomo.CurrencyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaimuTomo.Currency

  describe "normalize/1" do
    test "trims and uppercases a currency code" do
      assert Currency.normalize(" chf\n") == "CHF"
    end

    test "preserves nil" do
      assert Currency.normalize(nil) == nil
    end

    property "is idempotent for any input string" do
      check all(currency <- StreamData.string(:printable, max_length: 12)) do
        normalized = Currency.normalize(currency)
        assert Currency.normalize(normalized) == normalized
      end
    end

    property "trims whitespace padding around any core string" do
      check all(
              core <- StreamData.string(:alphanumeric, max_length: 6),
              leading <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 3),
              trailing <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 3)
            ) do
        assert Currency.normalize(leading <> core <> trailing) == String.upcase(core)
      end
    end
  end

  describe "normalize_and_validate/2" do
    property "is valid exactly when the normalized value is a three-letter uppercase code" do
      check all(
              core <- StreamData.string(:alphanumeric, max_length: 6),
              leading <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 2),
              trailing <- StreamData.string([?\s, ?\t, ?\n, ?\r], max_length: 2)
            ) do
        currency = leading <> core <> trailing

        changeset =
          Ecto.Changeset.cast({%{currency: nil}, %{currency: :string}}, %{currency: currency}, [
            :currency
          ])
          |> Currency.normalize_and_validate(:currency)

        # Ecto's cast/4 treats a blank string (one that trims to "") the same
        # as an absent param: no change is recorded, so neither
        # `update_change/3` nor `validate_format/3` runs at all.
        # Requiredness is deliberately the caller's job (see @moduledoc), so
        # a blank currency is valid *here* even though "" fails the format.
        expected_valid? =
          String.trim(currency) == "" or Currency.normalize(currency) =~ ~r/\A[A-Z]{3}\z/

        assert changeset.valid? == expected_valid?
      end
    end
  end
end
