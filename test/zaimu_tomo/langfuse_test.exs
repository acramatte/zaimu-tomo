defmodule ZaimuTomo.LangfuseTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.Langfuse

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
end
