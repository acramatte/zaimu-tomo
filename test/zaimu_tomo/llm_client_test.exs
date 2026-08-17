defmodule ZaimuTomo.LLMClientTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.ToolCall
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

    test "rejects unknown statuses instead of normalizing them into a valid one" do
      assert {:error, :verification_failed} =
               LLMClient.verification_result(%{"status" => "looks_good", "reason" => "Fine"})

      assert {:error, :verification_failed} =
               LLMClient.verification_result(%{"status" => "verified"})
    end
  end

  describe "verifier_object/1" do
    test "recovers structured output from a tool call when the response object is absent" do
      response = %Response{
        id: "resp-1",
        model: "gemma4-it:e4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [],
          tool_calls: [
            ToolCall.new(
              "call-1",
              "structured_output",
              ~s({"status":"needs_review","reason":"The invoice amount is 0.00.","field_issues":"amount_to_pay_cents"})
            )
          ]
        },
        object: nil,
        finish_reason: :tool_calls,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, %{"status" => "needs_review", "field_issues" => "amount_to_pay_cents"}} =
               LLMClient.verifier_object(response)
    end

    test "recovers structured output containing Gemma's invalid markdown escapes" do
      response = %Response{
        id: "resp-1",
        model: "gemma4-it:e4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [],
          tool_calls: [
            ToolCall.new(
              "call-1",
              "structured_output",
              ~s({"status":"needs_review","reason":"The invoice\\_date is ambiguous.","field_issues":"invoice_date"})
            )
          ]
        },
        object: nil,
        finish_reason: :tool_calls,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, %{"reason" => "The invoice_date is ambiguous."}} =
               LLMClient.verifier_object(response)
    end

    test "recovers structured output from plain text wrapped in markdown code fences" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [
            ContentPart.text(
              "\n```json\n{\n  \"status\": \"verified\",\n  \"reason\": \"All extracted values are directly supported by the source OCR markdown.\",\n  \"field_issues\": \"\"\n}\n```\n"
            )
          ],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, %{"status" => "verified"} = verification} = LLMClient.verifier_object(response)

      # empty field_issues is dropped by VerificationResult, so it is absent
      assert verification["reason"] ==
               "All extracted values are directly supported by the source OCR markdown."

      refute Map.has_key?(verification, "field_issues")
    end

    test "accepts a native response.object with a valid verifier object" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{role: :assistant, content: [], tool_calls: []},
        object: %{"status" => "verified", "reason" => "All fields grounded."},
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, %{"status" => "verified", "reason" => "All fields grounded."}} =
               LLMClient.verifier_object(response)
    end

    test "accepts needs_review and rejected statuses" do
      for status <- ["needs_review", "rejected"] do
        response = %Response{
          id: "resp-1",
          model: "phi4-mini-it:4b",
          context: nil,
          message: %Message{role: :assistant, content: [], tool_calls: []},
          object: %{"status" => status, "reason" => "For a reason."},
          finish_reason: :stop,
          provider_meta: %{},
          usage: %{}
        }

        assert {:ok, %{"status" => ^status}} = LLMClient.verifier_object(response)
      end
    end

    test "recovers plain-text JSON via unwrap_object" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [
            ContentPart.text(
              ~s({"status":"needs_review","reason":"Ambiguous amount.","field_issues":"amount"})
            )
          ],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, %{"status" => "needs_review"}} = LLMClient.verifier_object(response)
    end

    test "rejects an unknown status even when it decoded successfully" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{role: :assistant, content: [], tool_calls: []},
        object: %{"status" => "looks_good", "reason" => "Fine"},
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:error, :invalid_verifier_output} = LLMClient.verifier_object(response)
    end

    test "rejects a missing required reason" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{role: :assistant, content: [], tool_calls: []},
        object: %{"status" => "verified"},
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:error, :invalid_verifier_output} = LLMClient.verifier_object(response)
    end

    test "does not accept a repaired object that fails the verifier contract" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [
            ContentPart.text(
              "\n```json\n{\"status\": \"looks_good\", \"reason\": \"Fine\"}\n```\n"
            )
          ],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:error, :invalid_verifier_output} = LLMClient.verifier_object(response)
    end

    test "returns :no_structured_output when nothing usable is present" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [ContentPart.text("I cannot verify this.")],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:error, :no_structured_output} = LLMClient.verifier_object(response)
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

  describe "backend credentials" do
    test "rejects a selected backend without an API key before issuing a request" do
      original_backend_config = Application.fetch_env!(:zaimu_tomo, :nousresearch)

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :nousresearch, model: "ibm-granite/granite-4.1-8b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      Application.put_env(:zaimu_tomo, :nousresearch, api_key: nil)
      on_exit(fn -> Application.put_env(:zaimu_tomo, :nousresearch, original_backend_config) end)

      assert_raise ArgumentError, ~r/AI backend :nousresearch requires a non-empty api_key/, fn ->
        LLMClient.extract_invoice("Invoice total: CHF 12.00", "CHF")
      end
    end
  end

  describe "model_for/1" do
    test "uses independently configured models for roles sharing a backend" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "flm", model: "qwen3.5:9b"],
        verifier: [backend: "flm", model: "phi4-mini-it:4b"]
      )

      assert LLMClient.model_for(:extractor) == "qwen3.5:9b"
      assert LLMClient.model_for(:verifier) == "phi4-mini-it:4b"
    end

    test "resolves independently configured nousresearch models" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "nousresearch", model: "ibm-granite/granite-4.1-8b"],
        verifier: [backend: "nousresearch", model: "qwen/qwen3.6-35b-a3b"]
      )

      assert LLMClient.model_for(:extractor) == "ibm-granite/granite-4.1-8b"
      assert LLMClient.model_for(:verifier) == "qwen/qwen3.6-35b-a3b"
    end

    test "requires every role to configure its model" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "flm"],
        verifier: [backend: "flm", model: "phi4-mini-it:4b"]
      )

      assert_raise KeyError, fn -> LLMClient.model_for(:extractor) end
    end
  end

  describe "backend_for/1" do
    test "resolves string workflow backend names" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "ollama", model: "gemma4:e4b"],
        verifier: [backend: "flm", model: "phi4-mini-it:4b"]
      )

      assert LLMClient.backend_for(:extractor) == :ollama
      assert LLMClient.backend_for(:verifier) == :flm
    end

    test "accepts atom workflow backend names" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :ollama, model: "gemma4:e4b"]
      )

      assert LLMClient.backend_for(:extractor) == :flm
      assert LLMClient.backend_for(:verifier) == :ollama
    end

    test "accepts Mistral as extractor and verifier backend" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "mistral", model: "mistral-small-latest"],
        verifier: [backend: :mistral, model: "mistral-small-latest"]
      )

      assert LLMClient.backend_for(:extractor) == :mistral
      assert LLMClient.backend_for(:verifier) == :mistral
    end

    test "accepts nousresearch as extractor and verifier backend" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "nousresearch", model: "ibm-granite/granite-4.1-8b"],
        verifier: [backend: :nousresearch, model: "qwen/qwen3.6-35b-a3b"]
      )

      assert LLMClient.backend_for(:extractor) == :nousresearch
      assert LLMClient.backend_for(:verifier) == :nousresearch
    end

    test "raises for unknown workflow backends" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: "unknown", model: "unknown"],
        verifier: [backend: "flm", model: "phi4-mini-it:4b"]
      )

      assert_raise ArgumentError, ~r/unknown AI backend/, fn ->
        LLMClient.backend_for(:extractor)
      end
    end
  end
end
