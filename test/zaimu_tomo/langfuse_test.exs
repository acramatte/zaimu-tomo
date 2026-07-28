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
