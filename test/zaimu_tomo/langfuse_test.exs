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
end
