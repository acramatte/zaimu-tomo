defmodule ZaimuTomo.DocumentProcessing do
  @moduledoc """
  The DocumentProcessing context.

  This context handles the OCR processing workflow for documents.
  It coordinates between document uploads and the OCR processing via supervised tasks.
  """

  alias ZaimuTomo.DocumentProcessing.OCRSupervisor

  @doc """
  Processes a document through the supervised OCR pipeline.

  This is the main entry point for document processing. It starts a supervised
  OCR task that will process the document through the OCR pipeline.

  ## Parameters
    - document: A %ZaimuTomo.Documents.Document{} struct

  ## Returns
    - {:ok, pid} if the OCR task was started successfully
    - {:error, reason} if the task could not be started
  """
  def process_document(document) do
    OCRSupervisor.start_ocr(document)
  end

  @doc """
  Starts the OCR supervisor.

  This should be called when the application starts to enable supervised
  OCR processing.
  """
  def start_ocr_supervisor do
    OCRSupervisor.start_link(name: ZaimuTomo.OCRSupervisor)
  end

  @doc """
  Gets the current status of the document processing saga.

  Returns information about the Saga GenServer status.
  """
  def get_saga_status do
    GenServer.call(ZaimuTomo.DocumentProcessing.Saga, :status)
  end
end
