defmodule ZaimuTomo.LangfuseTest do
  use ExUnit.Case, async: false

  require Record

  alias ZaimuTomo.Langfuse

  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  setup do
    original_config = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    on_exit(fn ->
      if original_config do
        Application.put_env(:zaimu_tomo, :langfuse, original_config)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)
  end

  test "leaves document processing unchanged when Langfuse is not configured" do
    result =
      Langfuse.trace_document_processing(%{id: 123, user_id: 456}, fn ->
        {:ok, %{status: "success"}}
      end)

    assert result == {:ok, %{status: "success"}}
    refute Langfuse.enabled?()
  end

  test "leaves LLM generations unchanged when Langfuse is not configured" do
    assert Langfuse.trace_llm_generation("extract-invoice", "gemma", "prompt", fn ->
             {:ok, :response}
           end) == {:ok, :response}
  end

  test "uses the local prompt fallback when Langfuse is not configured" do
    assert {:ok, prompt} =
             Langfuse.fetch_prompt("extract-invoice", %{
               currency_hint: "CHF",
               ocr_markdown: "Invoice total: CHF 42.00"
             })

    assert prompt.id == "local:extract-invoice"
    assert prompt.version == 0
    assert prompt.content =~ "choose CHF when present"
    assert prompt.content =~ "OCR Text:\nInvoice total: CHF 42.00"
  end

  test "fetches and compiles the production prompt with its Langfuse metadata" do
    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      prompt_fetcher: fn "extract-invoice", "production" ->
        {:ok,
         %{
           "id" => "prompt-id",
           "name" => "extract-invoice",
           "version" => 7,
           "labels" => ["production"],
           "prompt" => "Extract {{currency_hint}} from {{ocr_markdown}}"
         }}
      end
    )

    assert {:ok, prompt} =
             Langfuse.fetch_prompt("extract-invoice", %{
               currency_hint: "CHF",
               ocr_markdown: "Invoice total: CHF 42.00"
             })

    assert prompt.content == "Extract CHF from Invoice total: CHF 42.00"
    assert prompt.name == "extract-invoice"
    assert prompt.version == 7
    assert prompt.label == "production"
  end

  test "returns a controlled error when a fetched prompt is missing required metadata" do
    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      prompt_fetcher: fn "extract-invoice", "production" ->
        {:ok, %{"id" => "prompt-id", "name" => "extract-invoice"}}
      end
    )

    assert {:error, :invalid_langfuse_prompt_response} =
             Langfuse.fetch_prompt("extract-invoice", %{})
  end

  test "returns a controlled error when a fetched prompt template is not text" do
    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      prompt_fetcher: fn "extract-invoice", "production" ->
        {:ok,
         %{
           "id" => "prompt-id",
           "name" => "extract-invoice",
           "version" => 7,
           "prompt" => %{}
         }}
      end
    )

    assert {:error, :invalid_langfuse_prompt_response} =
             Langfuse.fetch_prompt("extract-invoice", %{})
  end

  test "returns a controlled error when a prompt fetcher returns an unexpected value" do
    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      prompt_fetcher: fn "extract-invoice", "production" -> :unexpected end
    )

    assert {:error, :invalid_langfuse_prompt_response} =
             Langfuse.fetch_prompt("extract-invoice", %{})
  end

  test "returns a controlled error when a prompt fetcher raises" do
    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      prompt_fetcher: fn "extract-invoice", "production" -> raise "unavailable" end
    )

    assert {:error, :prompt_fetcher_failed} =
             Langfuse.fetch_prompt("extract-invoice", %{})
  end

  test "records a document-processing span without changing the workflow result" do
    Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")

    assert :ok = Langfuse.setup()

    result =
      Langfuse.trace_document_processing(%{id: 123, user_id: 456}, fn ->
        {:ok, %{status: "failed"}}
      end)

    assert result == {:ok, %{status: "failed"}}
    assert Langfuse.enabled?()
  end

  describe "trace_statement_extraction/2" do
    test "leaves statement extraction unchanged when Langfuse is not configured" do
      result =
        Langfuse.trace_statement_extraction(%{id: 123, user_id: 456}, fn ->
          assert Langfuse.current_trace_id() == nil
          :ok
        end)

      assert result == :ok
      refute Langfuse.enabled?()
    end

    test "emits a process-statement span with statement_id and user_id metadata when enabled" do
      Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")

      assert :ok = Langfuse.setup()

      result =
        Langfuse.trace_statement_extraction(%{id: 123, user_id: 456}, fn ->
          span_ctx = :otel_tracer.current_span_ctx()
          span_id = :otel_span.span_id(span_ctx)
          [active_span] = :ets.lookup(:otel_span_table, span_id)
          attributes = :otel_attributes.map(otel_span(active_span, :attributes))

          assert otel_span(active_span, :name) == "process-statement"
          assert attributes["langfuse.trace.name"] == "process-statement"
          assert attributes["langfuse.environment"] == "test"
          assert attributes["langfuse.user.id"] == "456"
          assert attributes["langfuse.trace.tags"] == ["statement-extraction", "test"]
          assert attributes["langfuse.trace.metadata.statement_id"] == "123"
          assert attributes["langfuse.trace.metadata.workflow"] == "statement-extraction"

          assert Jason.decode!(attributes["langfuse.observation.input"]) == %{
                   "workflow" => "statement-extraction"
                 }

          assert is_binary(Langfuse.current_trace_id())
          :ok
        end)

      assert result == :ok
      assert Langfuse.enabled?()
    end

    test "preserves cancel and error results when enabled" do
      Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")

      assert {:cancel, :statement_deleted} ==
               Langfuse.trace_statement_extraction(%{id: 123, user_id: 456}, fn ->
                 {:cancel, :statement_deleted}
               end)

      assert {:error, :timeout} ==
               Langfuse.trace_statement_extraction(%{id: 123, user_id: 456}, fn ->
                 {:error, :timeout}
               end)
    end
  end

  test "leaves custom spans unchanged when Langfuse is not configured" do
    assert Langfuse.trace_span("typesafe-shadow-verification", %{"model" => "jev-latest"}, fn ->
             :disabled
           end) == :disabled
  end

  test "records a custom span without changing the wrapped result" do
    Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")

    assert :ok = Langfuse.setup()

    result =
      Langfuse.trace_span("typesafe-shadow-verification", %{"model" => "jev-latest"}, fn ->
        {:ok, %{"status" => "verified", "model" => "jev-latest"}}
      end)

    assert result == {:ok, %{"status" => "verified", "model" => "jev-latest"}}
  end

  describe "current_trace_id/0" do
    test "returns nil when no span is active" do
      Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")
      assert Langfuse.current_trace_id() == nil
    end

    test "returns the hex trace id inside a traced document-processing span" do
      Application.put_env(:zaimu_tomo, :langfuse, enabled: true, environment: "test")

      trace_id =
        Langfuse.trace_document_processing(%{id: 123, user_id: 456}, fn ->
          Langfuse.current_trace_id()
        end)

      assert is_binary(trace_id)
      assert String.length(trace_id) == 32
    end
  end

  describe "create_user_score/3" do
    test "is a no-op when Langfuse is not configured" do
      assert Langfuse.create_user_score("trace-123", 1, "looks good") == :ok
    end

    test "sends a boolean score for correct extraction with a comment" do
      parent = self()

      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        score_sender: fn payload ->
          send(parent, {:score_payload, payload})
          {:ok, %{status: 200}}
        end
      )

      assert :ok = Langfuse.create_user_score("trace-123", 1, "Amount matched the PDF")

      assert_received {:score_payload, payload}
      assert payload.traceId == "trace-123"
      assert payload.name == "user-extraction-thumbs"
      assert payload.value == 1
      assert payload.dataType == "BOOLEAN"
      assert payload.comment == "Amount matched the PDF"
    end

    test "sends a boolean score for incorrect extraction and omits empty comments" do
      parent = self()

      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        score_sender: fn payload ->
          send(parent, {:score_payload, payload})
          {:ok, %{status: 200}}
        end
      )

      assert :ok = Langfuse.create_user_score("trace-456", 0, "")

      assert_received {:score_payload, payload}
      assert payload.traceId == "trace-456"
      assert payload.value == 0
      refute Map.has_key?(payload, :comment)
    end

    test "propagates a non-2xx response from the score sender" do
      Application.put_env(:zaimu_tomo, :langfuse,
        enabled: true,
        environment: "test",
        score_sender: fn _payload -> {:error, {:score_creation_failed, 500}} end
      )

      assert {:error, {:score_creation_failed, 500}} =
               Langfuse.create_user_score("trace-789", 0, "wrong amount")
    end
  end

  describe "generation_output_attributes/1" do
    test "records finish reason and reasoning so an empty result can be diagnosed" do
      response = %ReqLLM.Response{
        id: "resp-1",
        model: "granite",
        context: nil,
        message: %ReqLLM.Message{
          role: :assistant,
          content: [%ReqLLM.Message.ContentPart{type: :thinking, text: "weighing totals"}]
        },
        object: nil,
        finish_reason: :length,
        usage: %{input_tokens: 10, output_tokens: 4096}
      }

      attributes = Langfuse.generation_output_attributes(response)
      output = Jason.decode!(attributes["langfuse.observation.output"])

      assert output["finish_reason"] == "length"
      assert output["thinking"] == "weighing totals"
      assert output["object"] == nil
      assert attributes["langfuse.observation.metadata.finish_reason"] == "length"
      assert attributes["gen_ai.usage.output_tokens"] == 4096
    end
  end

  describe "failed_generation_attributes/1" do
    test "records the error reason so a failed generation can be diagnosed" do
      error = %ReqLLM.Error.API.Request{reason: "timeout", status: nil}

      output =
        {:error, error}
        |> Langfuse.failed_generation_attributes()
        |> Map.fetch!("langfuse.observation.output")
        |> Jason.decode!()

      assert output["status"] == "failed"
      assert output["error"] =~ "timeout"
    end

    test "records a bare failure for a result that is not an error tuple" do
      output =
        :unexpected
        |> Langfuse.failed_generation_attributes()
        |> Map.fetch!("langfuse.observation.output")
        |> Jason.decode!()

      assert output == %{"status" => "failed"}
    end
  end
end
