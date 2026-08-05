defmodule ZaimuTomo.DocumentProcessing.Worker do
  @moduledoc """
  Individual OCR processing task for a single document.
  Uses the existing DocumentOCR module for processing.
  """

  use Task

  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.Review
  require Logger

  def start_link(command) do
    Task.start_link(__MODULE__, :process, [command])
  end

  def process(%{document: %{filepath: filepath} = document, currency_hint: currency_hint}) do
    Langfuse.trace_document_processing(document, fn ->
      trace_id = Langfuse.current_trace_id()
      full_path = build_document_path(filepath)

      with {:ok, markdown, raw_llm_response} <- DocumentOCR.process(full_path),
           {:ok, extracted_data} <-
             ZaimuTomo.LLMClient.extract_invoice(markdown, currency_hint),
           {:ok, verification} <- ZaimuTomo.LLMClient.verify_extraction(markdown, extracted_data) do
        persist_and_emit_success(
          document,
          extracted_data,
          raw_llm_response,
          verification,
          trace_id
        )
      else
        {:error, reason} ->
          Logger.error("[Saga] Document #{document.id} processing failed: #{inspect(reason)}")
          persist_and_emit_failure(document, reason)
      end
    end)
  end

  def persist_and_emit_success(
        document,
        extracted_data,
        raw_llm_response,
        verification \\ %{"status" => "not_run"},
        trace_id \\ nil
      ) do
    analysis = %{
      "processed_at" => DateTime.utc_now(),
      "verification" => verification
    }

    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      extracted_data: extracted_data,
      raw_llm_response: raw_llm_response,
      analysis: analysis,
      status: "success",
      trace_id: trace_id
    }

    case ExtractedContentContext.create_extracted_content(extraction_params) do
      {:ok, content} ->
        {:ok, _review_decision} = Review.create_initial_decision(content)

        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:success", %{
          document_id: document.id,
          extraction_id: content.id,
          user_id: document.user_id,
          status: :completed,
          data: extracted_data,
          timestamp: DateTime.utc_now()
        })

        {:ok, content}

      {:error, changeset} ->
        Logger.error(
          "[Saga] Failed to persist successful extraction for document #{document.id}: #{inspect(changeset.errors)}"
        )

        {:error, {:persistence_failed, changeset.errors}}
    end
  end

  def persist_and_emit_failure(document, error) do
    error_details = %{
      "type" => error_type(error),
      "message" => error_message(error),
      "stack_trace" => error_stack_trace(error),
      "timestamp" => DateTime.utc_now()
    }

    # Failed extractions persist an empty extracted-data embed because invoice
    # fields are unavailable when processing does not complete.
    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      # Empty map - will fail validation as expected
      extracted_data: %{},
      analysis: %{
        "error" => "Extraction failed",
        "attempted_at" => DateTime.utc_now()
      },
      status: "failed",
      error_details: error_details
    }

    case ExtractedContentContext.create_extracted_content(extraction_params) do
      {:ok, content} ->
        {:ok, _review_decision} = Review.create_failed_decision(content, error)

        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:failed", %{
          document_id: document.id,
          extraction_id: content.id,
          user_id: document.user_id,
          status: :failed,
          error: error,
          timestamp: DateTime.utc_now()
        })

        {:ok, content}

      {:error, changeset} ->
        Logger.error(
          "[Saga] Failed to persist failed extraction for document #{document.id}: #{inspect(changeset.errors)}"
        )

        {:error, {:persistence_failed, changeset.errors}}
    end
  end

  defp build_document_path(filename) do
    Path.join([:code.priv_dir(:zaimu_tomo), "uploads", Path.basename(filename)])
  end

  # Error handling helper functions
  defp error_type(error) when is_tuple(error),
    do: elem(error, 0) |> to_string()

  defp error_type(error) when is_atom(error),
    do: Atom.to_string(error)

  defp error_type(_error),
    do: "unknown"

  defp error_message(error) when is_tuple(error) do
    val = elem(error, 1)
    if is_binary(val), do: val, else: inspect(val)
  end

  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp error_stack_trace(_error),
    do: []
end
