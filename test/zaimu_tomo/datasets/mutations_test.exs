defmodule ZaimuTomo.Datasets.MutationsTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Datasets.Mutations

  @ground_truth %{
    "amount_to_pay_cents" => 10_810,
    "currency" => "CHF",
    "invoice_date" => "2026-11-01",
    "invoice_number" => "INV-42",
    "issuer" => "Swisscom",
    "reason_for_payment" => "Mobile subscription"
  }

  test "generates deterministic, distinct realistic mutations differing on their named field" do
    all = Mutations.generate(@ground_truth, 42, count: 5, seed: "test-seed")
    assert length(all) == 5
    assert all == Mutations.generate(@ground_truth, 42, count: 5, seed: "test-seed")

    names = Enum.map(all, & &1.mutation)
    assert length(Enum.uniq(names)) == 5
    assert "subtotal_instead_of_total" in names
    assert "due_date_instead_of_invoice_date" in names
    assert "wrong_currency" in names
    assert "hallucinated_reason_for_payment" in names
    assert "hallucinated_issuer" in names

    for mutation <- all do
      assert mutation.expected_status == "rejected"
      assert [field] = mutation.field_issues
      assert mutation.candidate[field] != @ground_truth[field]
    end
  end

  test "mutates zero-amount invoices to 1 cent to mirror the real zero-amount bug" do
    zero_gt = Map.put(@ground_truth, "amount_to_pay_cents", 0)
    all = Mutations.generate(zero_gt, 94, count: 5, seed: "zero-seed")

    zero_mutation = Enum.find(all, &(&1.mutation == "zero_amount_one_cent"))
    assert zero_mutation != nil
    assert zero_mutation.candidate["amount_to_pay_cents"] == 1
    assert zero_mutation.field_issues == ["amount_to_pay_cents"]
  end

  test "returns an empty list when count is 0" do
    assert Mutations.generate(@ground_truth, 1, count: 0) == []
  end

  test "never flips the sign on small positive totals (1..6 cents) or negative credit notes" do
    for small_cents <- [1, 2, 5, 6] do
      gt = Map.put(@ground_truth, "amount_to_pay_cents", small_cents)

      mut =
        gt
        |> Mutations.generate(small_cents, count: 5)
        |> Enum.find(&(&1.field_issues == ["amount_to_pay_cents"]))

      assert mut.candidate["amount_to_pay_cents"] > 0
      assert mut.candidate["amount_to_pay_cents"] != small_cents
    end

    credit_gt = Map.put(@ground_truth, "amount_to_pay_cents", -500)

    credit_mut =
      credit_gt
      |> Mutations.generate(77, count: 5)
      |> Enum.find(&(&1.field_issues == ["amount_to_pay_cents"]))

    assert credit_mut.candidate["amount_to_pay_cents"] < 0
    assert credit_mut.candidate["amount_to_pay_cents"] != -500
  end
end
