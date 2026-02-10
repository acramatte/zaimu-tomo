defmodule ZaimuTomo.DocumentProcessing.OCRSupervisor do
  @moduledoc """
  Supervises OCR processing tasks.
  Each document gets its own supervised task for OCR processing.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts an OCR worker for the given `document`.

  Returns `{:ok, pid}` on success or `{:error, reason}`.

  Always uses the named OCR supervisor that should be started in the application
  supervision tree.
  """
  def start_ocr(document) do
    DynamicSupervisor.start_child(
      ZaimuTomo.OCRSupervisor,
      {ZaimuTomo.DocumentProcessing.Worker, document}
    )
  end
end
