defmodule ZaimuTomo.LLMClientTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ZaimuTomo.LLMClient

  setup do
    original_workflow = Application.fetch_env!(:zaimu_tomo, :ai_workflow)

    on_exit(fn ->
      Application.put_env(:zaimu_tomo, :ai_workflow, original_workflow)
    end)
  end

  describe "verification_result/1" do
    test "accepts structured verified response with explanation" do
      assert {:ok,
              %{
                "status" => "verified",
                "reason" => "All fields are grounded in OCR text.",
                "raw_response" => %{
                  "status" => "verified",
                  "reason" => "All fields are grounded in OCR text."
                }
              }} =
               LLMClient.verification_result(%{
                 "status" => "verified",
                 "reason" => "All fields are grounded in OCR text."
               })
    end

    test "normalizes structured needs review response and keeps field issues" do
      assert {:ok,
              %{
                "status" => "needs_review",
                "reason" => "Invoice date is ambiguous.",
                "field_issues" => "invoice_date"
              }} =
               LLMClient.verification_result(%{
                 status: "needs review",
                 reason: "Invoice date is ambiguous.",
                 field_issues: "invoice_date"
               })
    end

    test "rejects plain text responses" do
      assert LLMClient.verification_result("VERIFIED") == {:error, :verification_failed}
    end

    test "rejects missing result" do
      assert LLMClient.verification_result(nil) == {:error, :verification_failed}
    end

    test "builds auditable verifier failure results from malformed responses" do
      response = %Response{
        id: "resp-1",
        model: "mistral-small",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [ContentPart.text("I cannot format this as requested")],
          tool_calls: [%{name: "structured_output", arguments: %{status: "maybe"}}]
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{provider: :mistral},
        usage: %{input_tokens: 10, output_tokens: 8}
      }

      raw_response = LLMClient.verifier_response_payload(response, nil)

      assert Jason.encode!(raw_response)

      assert raw_response == %{
               "raw_object" => nil,
               "text" => "I cannot format this as requested",
               "tool_calls" => [%{name: "structured_output", arguments: %{status: "maybe"}}],
               "finish_reason" => :stop,
               "provider_meta" => %{provider: :mistral},
               "usage" => %{input_tokens: 10, output_tokens: 8}
             }

      assert LLMClient.verification_failure_result(raw_response, :verification_failed) == %{
               "status" => "verification_failed",
               "reason" => "Verifier did not return valid structured output.",
               "raw_response" => raw_response,
               "error" => ":verification_failed"
             }
    end
  end

  describe "verify_extraction/2" do
    test "rejects unsupported extraction payloads before calling the LLM" do
      assert LLMClient.verify_extraction("ocr markdown", "not json data") ==
               {:error, :invalid_extraction_payload}
    end
  end

  describe "request_failure/1" do
    test "does not retain provider request bodies in request failures" do
      error =
        struct(ReqLLM.Error.API.Request,
          reason: "connection refused",
          request_body: "OCR text containing sensitive document data"
        )

      assert LLMClient.request_failure(error) ==
               {:llm_request_failed, "connection refused"}
    end
  end

  describe "backend_for/1" do
    test "resolves string workflow config to known backend atoms" do
      Application.put_env(:zaimu_tomo, :ai_workflow, extractor: "ollama", verifier: "flm")

      assert LLMClient.backend_for(:extractor) == :ollama
      assert LLMClient.backend_for(:verifier) == :flm
    end

    test "accepts atom workflow config" do
      Application.put_env(:zaimu_tomo, :ai_workflow, extractor: :flm, verifier: :ollama)

      assert LLMClient.backend_for(:extractor) == :flm
      assert LLMClient.backend_for(:verifier) == :ollama
    end

    test "accepts Mistral as extractor and verifier backend" do
      Application.put_env(:zaimu_tomo, :ai_workflow, extractor: "mistral", verifier: :mistral)

      assert LLMClient.backend_for(:extractor) == :mistral
      assert LLMClient.backend_for(:verifier) == :mistral
    end

    test "raises for unknown workflow backends" do
      Application.put_env(:zaimu_tomo, :ai_workflow, extractor: "unknown", verifier: "flm")

      assert_raise ArgumentError, ~r/unknown AI backend/, fn ->
        LLMClient.backend_for(:extractor)
      end
    end
  end
end
