defmodule ZaimuTomo.DocumentProcessing.VerificationResultTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.DocumentProcessing.VerificationResult

  describe "parse/1" do
    test "parses a valid structured verification result" do
      attrs = %{
        "status" => "verified",
        "reason" => "All extracted fields are supported by the OCR markdown."
      }

      assert {:ok,
              %{
                "status" => "verified",
                "reason" => "All extracted fields are supported by the OCR markdown.",
                "raw_response" => ^attrs
              }} = VerificationResult.parse(attrs)
    end

    test "keeps optional field issues when present" do
      assert {:ok, result} =
               VerificationResult.parse(%{
                 "status" => "rejected",
                 "reason" => "The extracted total is contradicted by the OCR markdown.",
                 "field_issues" => "amount_to_pay_cents,currency"
               })

      assert result["status"] == "rejected"
      assert result["field_issues"] == "amount_to_pay_cents,currency"
    end

    test "omits blank optional field issues" do
      assert {:ok, result} =
               VerificationResult.parse(%{
                 "status" => "verified",
                 "reason" => "Grounded.",
                 "field_issues" => "  "
               })

      refute Map.has_key?(result, "field_issues")
    end

    test "normalizes status casing, surrounding whitespace, spaces, and hyphens" do
      for {input, expected} <- [
            {" VERIFIED ", "verified"},
            {"Needs Review", "needs_review"},
            {"needs-review", "needs_review"},
            {"REJECTED", "rejected"}
          ] do
        assert {:ok, result} =
                 VerificationResult.parse(%{
                   "status" => input,
                   "reason" => "Because #{input}"
                 })

        assert result["status"] == expected
      end
    end

    test "trims reason" do
      assert {:ok, result} =
               VerificationResult.parse(%{
                 "status" => "needs_review",
                 "reason" => "  The invoice date is ambiguous.  "
               })

      assert result["reason"] == "The invoice date is ambiguous."
    end

    test "accepts atom keys while preserving original raw response" do
      attrs = %{
        status: "needs review",
        reason: "The OCR text is incomplete.",
        field_issues: "issuer"
      }

      assert {:ok, result} = VerificationResult.parse(attrs)
      assert result["status"] == "needs_review"
      assert result["field_issues"] == "issuer"
      assert result["raw_response"] == attrs
    end

    test "rejects unknown statuses" do
      assert {:error, changeset} =
               VerificationResult.parse(%{
                 "status" => "maybe",
                 "reason" => "Unclear."
               })

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "requires status and reason" do
      assert {:error, changeset} = VerificationResult.parse(%{})

      assert %{status: ["can't be blank"], reason: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
