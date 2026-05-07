defmodule ZaimuTomo.DocumentProcessing.Worker do
  @moduledoc """
  Individual OCR processing task for a single document.
  Uses the existing DocumentOCR module for processing.
  """

  use Task
  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.Review
  require Logger

  def start_link(document) do
    Task.start_link(__MODULE__, :process, [document])
  end

  def process(%{filepath: filepath} = document) do
    full_path = build_document_path(filepath)

    case DocumentOCR.process(full_path) do
      {:ok, extracted_data} ->
        persist_and_emit_success(document, extracted_data)

      {:error, reason} ->
        persist_and_emit_failure(document, reason)
    end
  end

  def persist_and_emit_success(document, extracted_data) do
    analysis = %{"processed_at" => DateTime.utc_now()}

    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      extracted_data: extracted_data,
      analysis: analysis,
      status: "success"
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

    # For failed extractions, we'll let the changeset handle validation
    # Pass empty map and let ExtractedData changeset validate required fields
    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      extracted_data: %{},  # Empty map - will fail validation as expected
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

  defp error_message(error) when is_tuple(error),
    do: elem(error, 1) |> to_string()
  defp error_message(error) when is_atom(error),
    do: Atom.to_string(error)
  defp error_message(error) when is_binary(error),
    do: error
  defp error_message(_error),
    do: "unknown error"

  defp error_stack_trace(_error),
    do: []
end
