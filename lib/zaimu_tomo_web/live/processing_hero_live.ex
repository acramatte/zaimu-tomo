defmodule ZaimuTomoWeb.ProcessingHeroLive do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents

  on_mount {ZaimuTomoWeb.UserAuth, :require_authenticated}

  @prune_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      DocumentProcessing.subscribe_events(socket.assigns.current_scope)
      schedule_prune()
    end

    {:ok,
     assign(
       socket,
       :processing_docs,
       processing_documents(socket.assigns.current_scope)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.processing_hero documents={@processing_docs} />
    """
  end

  @impl true
  def handle_info({:created, %ZaimuTomo.Documents.Document{}}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(%{document_id: _id, user_id: uid}, socket)
      when uid == socket.assigns.current_scope.user.id do
    {:noreply, refresh(socket)}
  end

  def handle_info(:prune_processing_docs, socket) do
    schedule_prune()

    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    assign(socket, :processing_docs, processing_documents(socket.assigns.current_scope))
  end

  # Documents with a live OCR job, from durable job state (two batched queries).
  defp processing_documents(scope) do
    documents = Documents.list_documents(scope)
    states = DocumentProcessing.processing_states(Enum.map(documents, & &1.id))
    Enum.filter(documents, &(states[&1.id] == :processing))
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_processing_docs, @prune_interval_ms)
  end
end
