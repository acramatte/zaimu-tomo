defmodule ZaimuTomo.DocumentProcessing.Worker do
  @moduledoc """
  Individual OCR processing task for a single document.
  Uses the existing DocumentOCR module for processing.
  """

  use Task
  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  require Logger

  def start_link(document) do
    Task.start_link(__MODULE__, :process, [document])
  end

  def process(%{filepath: filepath} = document) do
    full_path = build_document_path(filepath)

    case DocumentOCR.process(full_path) do
      {:ok, extracted_data} ->
        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:success", %{
          document_id: document.id,
          status: :completed,
          data: extracted_data,
          timestamp: DateTime.utc_now()
        })

        {:ok, extracted_data}

      {:error, reason} ->
        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:failed", %{
          document_id: document.id,
          status: :failed,
          error: reason,
          timestamp: DateTime.utc_now()
        })

        {:error, reason}
    end
  end

  defp build_document_path(filename) do
    Path.join([:code.priv_dir(:zaimu_tomo), "uploads", Path.basename(filename)])
  end
end
