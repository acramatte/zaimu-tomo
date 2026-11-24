defmodule ZaimuTomo.LLMClientTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.ToolCall
  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.LLMClient

  defmodule StalledStub do
    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      send(test_pid, :stalled_request)
      Process.sleep(1_000)
      Plug.Conn.send_resp(conn, 200, "{}")
    end
  end

  defmodule OllamaStub do
    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:ollama_request, conn.request_path, conn.req_headers, request})

      content =
        case request["model"] do
          "extractor" ->
            Jason.encode!(%{
              amount_to_pay_cents: 1200,
              invoice_date: "2026-01-01",
              currency: "CHF",
              reason_for_payment: "Services",
              issuer: "Example Ltd"
            })

          # Production EWZ response from granite-4.2-8b: it ignored the forced
          # structured_output tool call and answered with JSON message text.
          "extractor-text-only" ->
            Jason.encode!(%{
              amount_to_pay_cents: 6995,
              invoice_date: "2026-09-25",
              invoice_number: "14 000 269 053",
              currency: "CHF",
              reason_for_payment: "Electricity bill payment",
              issuer: "Elektrizitätswerk der Stadt Zürich"
            })

          "extractor-no-reason" ->
            Jason.encode!(%{
              amount_to_pay_cents: 13_940,
              invoice_date: "2026-07-18",
              currency: "CHF",
              reason_for_payment: nil,
              issuer: "Coop Genossenschaft"
            })

          _verifier ->
            Jason.encode!(%{status: "verified", reason: "All fields match."})
        end

      response = %{
        id: "test-response",
        model: request["model"],
        choices: [
          %{
            index: 0,
            message: %{role: "assistant", content: content},
            finish_reason: "stop"
          }
        ],
        usage: %{prompt_tokens: 10, completion_tokens: 10, total_tokens: 20}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

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
            ContentPart.text(~S"""

            ```json
            {
              "status": "verified",
              "reason": "All extracted values are directly supported by the source OCR markdown.",
              "field_issues": ""
            }
            ```
            """)
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
            ContentPart.text(~S"""

            ```json
            {"status": "looks_good", "reason": "Fine"}
            ```
            """)
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

    test "recovers the verdict from labeled prose without JSON" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [
            ContentPart.text("""
            Status: verified
            Reason: All extracted values are directly supported by the source OCR markdown.
            Field Issues: None.
            """)
          ],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:ok, verification} = LLMClient.verifier_object(response)
      assert verification["status"] == "verified"

      assert verification["reason"] ==
               "All extracted values are directly supported by the source OCR markdown."

      assert verification["field_issues"] == "None."
    end

    test "rejects prose whose status is not a verifier status" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [ContentPart.text("Status: looks_good\nReason: Fine.")],
          tool_calls: []
        },
        object: nil,
        finish_reason: :stop,
        provider_meta: %{},
        usage: %{}
      }

      assert {:error, :invalid_verifier_output} = LLMClient.verifier_object(response)
    end

    test "returns :no_structured_output for prose without a status label" do
      response = %Response{
        id: "resp-1",
        model: "phi4-mini-it:4b",
        context: nil,
        message: %Message{
          role: :assistant,
          content: [ContentPart.text("Reason: Everything matches the OCR markdown.")],
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
               {:llm_request_failed, %{status: nil, reason: "connection refused"}}
    end
  end

  describe "backend credentials" do
    test "rejects a selected backend without an API key before issuing a request" do
      original_backend_config = Application.fetch_env!(:zaimu_tomo, :nousresearch)

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :nousresearch, model: "ibm-granite/granite-4.2-8b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      Application.put_env(:zaimu_tomo, :nousresearch, api_key: nil)
      on_exit(fn -> Application.put_env(:zaimu_tomo, :nousresearch, original_backend_config) end)

      assert_raise ArgumentError, ~r/AI backend :nousresearch requires a non-empty api_key/, fn ->
        LLMClient.extract_invoice("Invoice total: CHF 12.00", "CHF")
      end
    end

    test "extracts and verifies through Ollama without credentials" do
      original_config = Application.fetch_env!(:zaimu_tomo, :ollama)
      original_langfuse = Application.fetch_env!(:zaimu_tomo, :langfuse)

      on_exit(fn ->
        Application.put_env(:zaimu_tomo, :ollama, original_config)
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      end)

      server =
        start_supervised!({Bandit, plug: {OllamaStub, self()}, ip: {127, 0, 0, 1}, port: 0})

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

      Application.put_env(:zaimu_tomo, :ollama,
        provider: :ollama,
        base_url: "http://127.0.0.1:#{port}/v1"
      )

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor"],
        verifier: [backend: :ollama, model: "verifier"]
      )

      assert {:ok, extracted} = LLMClient.extract_invoice("Invoice total: CHF 12.00", "CHF")
      assert extracted.amount_to_pay_cents == 1200

      assert {:ok, %{"status" => "verified", "verifier_model" => "verifier"} = verdict} =
               LLMClient.verify_extraction("Invoice total: CHF 12.00", extracted)

      assert is_integer(verdict["prompt_version"])

      for model <- ["extractor", "verifier"] do
        assert_receive {:ollama_request, "/v1/chat/completions", headers, body}
        refute List.keymember?(headers, "authorization", 0)
        assert body["model"] == model
        assert body["messages"] != []
        assert body["response_format"]["type"] == "json_schema"
        assert is_map(body["response_format"]["json_schema"]["schema"]["properties"])
      end
    end

    test "extracts an invoice an OpenAI-compatible model returned as text instead of a tool call" do
      use_openai_stub_extractor("extractor-text-only")

      assert {:ok, extracted} = LLMClient.extract_invoice("EWZ invoice", "CHF")

      assert extracted.amount_to_pay_cents == 6995
      assert extracted.invoice_date == "2026-09-25"
      assert extracted.invoice_number == "14 000 269 053"
      assert extracted.issuer == "Elektrizitätswerk der Stadt Zürich"
      assert_receive {:ollama_request, "/v1/chat/completions", _headers, body}
      assert body["tool_choice"]["function"]["name"] == "structured_output"
    end

    test "extracts an invoice whose items give no reason for payment" do
      use_openai_stub_extractor("extractor-no-reason")

      assert {:ok, extracted} = LLMClient.extract_invoice("Coop invoice", "CHF")

      assert extracted.amount_to_pay_cents == 13_940
      assert extracted.reason_for_payment == nil
      assert extracted.issuer == "Coop Genossenschaft"
    end
  end

  defp use_openai_stub_extractor(model) do
    original_config = Application.fetch_env!(:zaimu_tomo, :nousresearch)
    original_langfuse = Application.fetch_env!(:zaimu_tomo, :langfuse)

    on_exit(fn ->
      Application.put_env(:zaimu_tomo, :nousresearch, original_config)
      Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
    end)

    server =
      start_supervised!({Bandit, plug: {OllamaStub, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

    Application.put_env(:zaimu_tomo, :nousresearch,
      provider: :openai,
      base_url: "http://127.0.0.1:#{port}/v1",
      api_key: "test-key"
    )

    Application.put_env(:zaimu_tomo, :ai_workflow,
      extractor: [backend: :nousresearch, model: model],
      verifier: [backend: :nousresearch, model: "verifier"]
    )
  end

  describe "extract_statement_page/2" do
    setup do
      for key <- [:ollama, :langfuse] do
        original = Application.fetch_env!(:zaimu_tomo, key)
        on_exit(fn -> Application.put_env(:zaimu_tomo, key, original) end)
      end

      Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

      Application.put_env(:zaimu_tomo, :ollama,
        provider: :ollama,
        base_url: "http://llm.test/v1",
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      )

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor"],
        verifier: [backend: :ollama, model: "verifier"]
      )

      :ok
    end

    @context %{
      page: 2,
      pages: 3,
      account_type: :credit_card,
      currency: "CHF",
      period: {~D[2026-10-01], ~D[2026-10-31]}
    }

    defp stub_completion(content) do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:llm_request, Jason.decode!(body)})

        Req.Test.json(conn, %{
          id: "test",
          model: "extractor",
          choices: [
            %{index: 0, message: %{role: "assistant", content: content}, finish_reason: "stop"}
          ],
          usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
        })
      end)
    end

    test "asks for one page with the local prompt and a list-of-lines schema, and types the answer" do
      stub_completion(
        Jason.encode!(%{
          "closing_balance_cents" => -6_700,
          "lines" => [
            %{
              "booking_date" => "2026-10-20",
              "description" => "Hotel Roma",
              "amount_cents" => 2_500,
              "direction" => "debit"
            }
          ]
        })
      )

      assert {:ok,
              %{
                closing_balance_cents: -6_700,
                period_start: nil,
                lines: [%{booking_date: ~D[2026-10-20], amount_cents: 2_500, direction: :debit}]
              }} = LLMClient.extract_statement_page("| 20.10 | Hotel Roma | 25.00 |", @context)

      assert_receive {:llm_request, body}
      [%{"content" => prompt}] = body["messages"]
      assert prompt =~ "This is page 2 of 3. The account is a credit card account in CHF."
      assert prompt =~ "Statement period printed on an earlier page: 2026-10-01 to 2026-10-31."
      assert prompt =~ "| 20.10 | Hotel Roma | 25.00 |"

      line_schema = body["response_format"]["json_schema"]["schema"]["properties"]["lines"]
      assert line_schema["type"] == "array"
      assert line_schema["items"]["properties"]["direction"]["enum"] == ["debit", "credit"]
      assert "amount_cents" in line_schema["items"]["required"]
    end

    test "tells the first page that no period is known yet" do
      stub_completion(Jason.encode!(%{"lines" => []}))
      LLMClient.extract_statement_page("page", %{@context | page: 1, period: nil})

      assert_receive {:llm_request, %{"messages" => [%{"content" => prompt}]}}
      assert prompt =~ "Statement period printed on an earlier page: none yet."
    end

    test "refuses an answer that does not parse as a page" do
      stub_completion(Jason.encode!(%{"lines" => [%{"booking_date" => "20.10.2026"}]}))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:validation_failed, %{"lines.0.booking_date" => "is invalid"}}} =
                   LLMClient.extract_statement_page("page", @context)
        end)

      assert log =~ "Statement page failed schema validation"
      assert log =~ "lines.0.booking_date"
    end

    test "logs and returns prompt fetch failures before calling the LLM" do
      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        prompt_fetcher: fn "extract-statement-page", "production" ->
          {:error, {:prompt_fetch_failed, 503}}
        end
      )

      Req.Test.stub(__MODULE__, fn _conn -> flunk("unexpected HTTP request") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:prompt_fetch_failed, 503}} =
                   LLMClient.extract_statement_page("page", @context)
        end)

      assert log =~ "Statement page prompt fetch failed"
    end

    test "returns a refused request as a request failure with its status" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 400, "bad request"))

      capture_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:llm_request_failed, %{status: 400}}} =
                   LLMClient.extract_statement_page("page", @context)
        end)

      assert capture_log =~ "Statement page request failed"
    end

    test "sends the extractor's configured max tokens" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor", max_tokens: 6000],
        verifier: [backend: :ollama, model: "verifier"]
      )

      stub_completion(Jason.encode!(%{"lines" => []}))
      LLMClient.extract_statement_page("page", @context)

      assert_receive {:llm_request, body}
      assert body["max_tokens"] == 6000
    end

    test "times out after one request instead of retrying inside ReqLLM" do
      server =
        start_supervised!({Bandit, plug: {StalledStub, self()}, ip: {127, 0, 0, 1}, port: 0})

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      Application.put_env(:zaimu_tomo, :ollama,
        provider: :ollama,
        base_url: "http://127.0.0.1:#{port}/v1"
      )

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor", receive_timeout: 100],
        verifier: [backend: :ollama, model: "verifier"]
      )

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:llm_request_failed, %{status: nil, reason: "timeout"}}} =
                 LLMClient.extract_statement_page("page", @context)
      end)

      assert_received :stalled_request
      refute_receive :stalled_request, 300
    end

    test "rejects invalid page contexts before issuing an HTTP request" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("unexpected HTTP request") end)

      invalid_contexts = [
        %{@context | page: 0},
        %{@context | page: 4},
        %{@context | account_type: "credit card"},
        %{@context | account_type: :unknown},
        %{@context | currency: "CH"},
        %{@context | period: :bad},
        %{@context | period: {~D[2026-10-01], "2026-10-31"}}
      ]

      for invalid_context <- invalid_contexts do
        assert_raise FunctionClauseError, fn ->
          LLMClient.extract_statement_page("page", invalid_context)
        end
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
        extractor: [backend: "nousresearch", model: "ibm-granite/granite-4.2-8b"],
        verifier: [backend: "nousresearch", model: "qwen/qwen3.6-35b-a3b"]
      )

      assert LLMClient.model_for(:extractor) == "ibm-granite/granite-4.2-8b"
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

  describe "extractor_max_tokens/0" do
    test "reads the per-role max_tokens when configured" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :nousresearch, model: "ibm-granite/granite-4.2-8b", max_tokens: 6000],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      assert LLMClient.extractor_max_tokens() == 6000
    end

    test "falls back to a reasoning-friendly default when max_tokens is unset" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      assert LLMClient.extractor_max_tokens() == 8192
    end
  end

  describe "extract_invoice/2 against a stalled endpoint" do
    test "times out after one request instead of retrying inside ReqLLM" do
      original_config = Application.fetch_env!(:zaimu_tomo, :ollama)
      original_langfuse = Application.fetch_env!(:zaimu_tomo, :langfuse)

      on_exit(fn ->
        Application.put_env(:zaimu_tomo, :ollama, original_config)
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      end)

      server =
        start_supervised!({Bandit, plug: {StalledStub, self()}, ip: {127, 0, 0, 1}, port: 0})

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

      Application.put_env(:zaimu_tomo, :ollama,
        provider: :ollama,
        base_url: "http://127.0.0.1:#{port}/v1"
      )

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor", receive_timeout: 100],
        verifier: [backend: :ollama, model: "verifier"]
      )

      assert {:error, {:llm_request_failed, %{status: nil, reason: "timeout"}}} =
               LLMClient.extract_invoice("Invoice total: CHF 12.00", "CHF")

      assert_received :stalled_request
      refute_receive :stalled_request, 300
    end
  end

  describe "extractor_receive_timeout/0" do
    test "reads the per-role receive_timeout when configured" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b", receive_timeout: 90_000],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      assert LLMClient.extractor_receive_timeout() == 90_000
    end

    test "falls back to a window long enough for unstreamed generations" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b", receive_timeout: 0],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      assert LLMClient.extractor_receive_timeout() == 120_000
    end
  end

  describe "verify_extraction/2 against a stalled endpoint" do
    test "sends one request and returns the timeout for VerificationJob to retry" do
      original_config = Application.fetch_env!(:zaimu_tomo, :ollama)
      original_langfuse = Application.fetch_env!(:zaimu_tomo, :langfuse)

      on_exit(fn ->
        Application.put_env(:zaimu_tomo, :ollama, original_config)
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      end)

      server =
        start_supervised!({Bandit, plug: {StalledStub, self()}, ip: {127, 0, 0, 1}, port: 0})

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      Application.put_env(:zaimu_tomo, :langfuse, enabled: false)

      Application.put_env(:zaimu_tomo, :ollama,
        provider: :ollama,
        base_url: "http://127.0.0.1:#{port}/v1"
      )

      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :ollama, model: "extractor"],
        verifier: [backend: :ollama, model: "verifier", receive_timeout: 100]
      )

      assert {:error, {:llm_request_failed, %{status: nil, reason: reason}} = failure} =
               LLMClient.verify_extraction("Invoice total: CHF 12.00", %{
                 "amount_to_pay_cents" => 1200
               })

      assert reason =~ "timeout"
      assert ErrorClassification.classify(failure) == :transient
      assert_received :stalled_request
      refute_receive :stalled_request, 300
    end
  end

  describe "verifier_receive_timeout/0" do
    test "reads the per-role receive_timeout when configured" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b", receive_timeout: 90_000]
      )

      assert LLMClient.verifier_receive_timeout() == 90_000
    end

    test "falls back to a window long enough for unstreamed generations" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b"]
      )

      assert LLMClient.verifier_receive_timeout() == 120_000
    end
  end

  describe "verifier_max_tokens/0" do
    test "reads the per-role max_tokens when configured" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :nousresearch, model: "qwen/qwen3.6-35b-a3b", max_tokens: 8192]
      )

      assert LLMClient.verifier_max_tokens() == 8192
    end

    test "falls back to a reasoning-friendly default when max_tokens is unset" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :nousresearch, model: "qwen/qwen3.6-35b-a3b"]
      )

      assert LLMClient.verifier_max_tokens() == 4096
    end

    test "rejects a non-positive configured max_tokens with the default" do
      Application.put_env(:zaimu_tomo, :ai_workflow,
        extractor: [backend: :flm, model: "gemma4-it:e4b"],
        verifier: [backend: :flm, model: "phi4-mini-it:4b", max_tokens: 0]
      )

      assert LLMClient.verifier_max_tokens() == 4096
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
        extractor: [backend: "nousresearch", model: "ibm-granite/granite-4.2-8b"],
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
