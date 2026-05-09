defmodule ZaimuTomo.Review.ReviewDecisionTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Review.ReviewDecision

  describe "effective_data/1" do
    test "returns empty map when both fields are nil" do
      decision = %ReviewDecision{original_data: nil, decision_data: nil}
      assert ReviewDecision.effective_data(decision) == %{}
    end

    test "returns original_data when decision_data is nil" do
      decision = %ReviewDecision{
        original_data: %{"issuer" => "ACME", "amount_to_pay_cents" => 1000},
        decision_data: nil
      }
      assert ReviewDecision.effective_data(decision) == %{"issuer" => "ACME", "amount_to_pay_cents" => 1000}
    end

    test "returns decision_data when original_data is nil" do
      decision = %ReviewDecision{
        original_data: nil,
        decision_data: %{"issuer" => "Amended Co", "amount_to_pay_cents" => 2000}
      }
      assert ReviewDecision.effective_data(decision) == %{"issuer" => "Amended Co", "amount_to_pay_cents" => 2000}
    end

    test "decision_data overrides original_data for shared keys" do
      decision = %ReviewDecision{
        original_data: %{"issuer" => "Original Co", "amount_to_pay_cents" => 1000, "currency" => "USD"},
        decision_data: %{"issuer" => "Amended Co", "amount_to_pay_cents" => 1500}
      }
      result = ReviewDecision.effective_data(decision)
      assert result["issuer"] == "Amended Co"
      assert result["amount_to_pay_cents"] == 1500
    end

    test "keys absent from decision_data are preserved from original_data" do
      decision = %ReviewDecision{
        original_data: %{"issuer" => "ACME", "currency" => "USD", "invoice_number" => "INV-001"},
        decision_data: %{"issuer" => "Amended Co"}
      }
      result = ReviewDecision.effective_data(decision)
      assert result["currency"] == "USD"
      assert result["invoice_number"] == "INV-001"
    end

    test "merges disjoint keys from both maps" do
      decision = %ReviewDecision{
        original_data: %{"invoice_number" => "INV-001"},
        decision_data: %{"reason_for_payment" => "Consulting"}
      }
      result = ReviewDecision.effective_data(decision)
      assert result["invoice_number"] == "INV-001"
      assert result["reason_for_payment"] == "Consulting"
    end
  end
end
