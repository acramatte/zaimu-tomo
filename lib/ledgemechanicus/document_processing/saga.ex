defmodule Ledgemechanicus.DocumentProcessing.Saga do
  @moduledoc """
  Process manager that reacts to `:document_uploaded` events
  and starts the OCR workflow via `Ledgemechanicus.DocumentProcessing.OCRSupervisor`.

  It also exposes a simple `status/0` call that returns `:running`.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Returns the current health status of the saga.
  """
  @spec status() :: :running | :stopped
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Ledgemechanicus.PubSub, "documents_uploaded")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, :running, state}
  end

  @impl true
  def handle_info({:created, %Ledgemechanicus.Documents.Document{} = document}, state) do
    case Ledgemechanicus.DocumentProcessing.process_document(document) do
      {:ok, _pid} ->
        Logger.info("[Saga] Started OCR processing for document #{document.id}")
        :ok

      {:error, reason} ->
        Logger.error("[Saga] Failed to start OCR processing: #{inspect(reason)}")
        :ok
    end

    {:noreply, state}
  end

  # Ignore other document events (updated, deleted) that we don't handle
  def handle_info({:updated, _document}, state), do: {:noreply, state}
  def handle_info({:deleted, _document}, state), do: {:noreply, state}
end
