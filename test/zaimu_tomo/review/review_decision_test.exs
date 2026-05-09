defmodule ZaimuTomo.Review.ReviewDecisionTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.DocumentProcessing.ExtractedData

  describe "decision_data || original_data priority" do
    test "returns original_data when decision_data is nil" do
      original = %ExtractedData{issuer: "ACME", amount_to_pay_cents: 1000, currency: "USD",
                                invoice_number: "INV-001", invoice_date: "2024-01-15",
                                reason_for_payment: "Services"}
      decision = %ReviewDecision{original_data: original, decision_data: nil}
      assert (decision.decision_data || decision.original_data).issuer == "ACME"
    end

    test "returns decision_data when present, overriding original" do
      original = %ExtractedData{issuer: "Original Co", amount_to_pay_cents: 1000, currency: "USD",
                                invoice_number: "INV-001", invoice_date: "2024-01-15",
                                reason_for_payment: "Services"}
      amended = %ExtractedData{issuer: "Amended Co", amount_to_pay_cents: 1500, currency: "USD",
                               invoice_number: "INV-001", invoice_date: "2024-01-15",
                               reason_for_payment: "Services"}
      decision = %ReviewDecision{original_data: original, decision_data: amended}
      result = decision.decision_data || decision.original_data
      assert result.issuer == "Amended Co"
      assert result.amount_to_pay_cents == 1500
    end
  end
end
