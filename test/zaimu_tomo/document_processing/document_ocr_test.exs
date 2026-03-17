defmodule ZaimuTomo.DocumentProcessing.DocumentOCRTest do
  use ZaimuTomo.DataCase
  alias ZaimuTomo.DocumentProcessing.DocumentOCR

  describe "extract_data/1" do
    test "successfully parses a valid Mistral response" do
      # simulates the nested JSON structure Mistral returns
      llm_json_content = Jason.encode!(%{
        "amount_to_pay_cents" => 1500,
        "currency" => "EUR",
        "invoice_date" => "2024-03-17",
        "invoice_number" => "INV-001",
        "issuer" => "ACME Corp",
        "reason_for_payment" => "Software Services"
      })

      mock_body = %{
        "choices" => [
          %{"message" => %{"content" => llm_json_content}}
        ]
      }

      assert {:ok, %ZaimuTomo.DocumentProcessing.ExtractedData{} = data} =
               DocumentOCR.extract_data(mock_body)

      assert data.amount_to_pay_cents == 1500
      assert data.issuer == "ACME Corp"
    end

    test "returns error for malformed API structure" do
      bad_body = %{"something" => "unexpected"}

      assert {:error, :unexpected_api_structure} = DocumentOCR.extract_data(bad_body)
    end

    test "returns error when LLM returns invalid JSON string" do
      mock_body = %{
        "choices" => [
          %{"message" => %{"content" => "I am not a JSON string, I am a hallucination!"}}
        ]
      }

      assert {:error, :invalid_json_from_llm} = DocumentOCR.extract_data(mock_body)
    end

    test "returns error when data fails schema validation" do
      # Missing required fields like 'currency'
      incomplete_json = Jason.encode!(%{"amount_to_pay_cents" => 100})

      mock_body = %{
        "choices" => [
          %{"message" => %{"content" => incomplete_json}}
        ]
      }

      assert {:error, {:validation_failed, _errors}} = DocumentOCR.extract_data(mock_body)
    end
  end
end
