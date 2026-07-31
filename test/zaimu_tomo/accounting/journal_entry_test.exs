defmodule ZaimuTomo.Accounting.JournalEntryTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Accounting.JournalEntry

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

  test "rejects a currency with a trailing newline" do
    changeset = JournalEntry.changeset_for_create(valid_attrs(%{currency: "USD\n"}))

    refute changeset.valid?
  end

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
