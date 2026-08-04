defmodule ZaimuTomo.CurrencyTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Currency

  describe "normalize/1" do
    test "trims and uppercases a currency code" do
      assert Currency.normalize(" chf\n") == "CHF"
    end

    test "preserves nil" do
      assert Currency.normalize(nil) == nil
    end
  end
end
