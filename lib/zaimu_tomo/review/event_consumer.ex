defmodule ZaimuTomo.Review.EventConsumer do
  @moduledoc """
  Event consumer for document processing events.
  
  This module subscribes to document processing events and updates the review system
  accordingly. It handles both success and failure events from the OCR/LLM pipeline.
  """

  use GenServer
  require Logger

  alias ZaimuTomo.Review

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Subscribe to document processing events
    Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")
    Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:broadcast, "document_processing:success", payload}, state) do
    handle_success_event(payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:broadcast, "document_processing:failed", payload}, state) do
    handle_failure_event(payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Event handlers
  defp handle_success_event(payload) do
    case Review.handle_document_processing_success(payload) do
      {:ok, _content} ->
        :ok
      {:error, error} ->
        Logger.error("Failed to handle document processing success: #{inspect(error)}")
        :error
    end
  end

  defp handle_failure_event(payload) do
    case Review.handle_document_processing_failure(payload) do
      {:ok, _content} ->
        :ok
      {:error, error} ->
        Logger.error("Failed to handle document processing failure: #{inspect(error)}")
        :error
    end
  end
end