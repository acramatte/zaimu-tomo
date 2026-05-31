defmodule ZaimuTomoWeb.ProcessingHeroLive do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Documents

  on_mount {ZaimuTomoWeb.UserAuth, :require_authenticated}

  @processing_window_seconds 10 * 60
  @prune_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")
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
  def handle_info({:created, %ZaimuTomo.Documents.Document{} = document}, socket) do
    {:noreply, add_processing_document(socket, document)}
  end

  def handle_info(%{document_id: id, user_id: uid}, socket)
      when uid == socket.assigns.current_scope.user.id do
    {:noreply,
     socket
     |> remove_processing_document(id)
     |> assign(:processing_docs, processing_documents(socket.assigns.current_scope))}
  end

  def handle_info(:prune_processing_docs, socket) do
    schedule_prune()

    {:noreply, assign(socket, :processing_docs, processing_documents(socket.assigns.current_scope))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp processing_documents(scope) do
    scope
    |> Documents.list_documents()
    |> Enum.filter(&processing_document?/1)
  end

  defp processing_document?(document) do
    List.first(document.extracted_content) == nil and recently_uploaded?(document)
  end

  defp recently_uploaded?(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) <= @processing_window_seconds
  end

  defp recently_uploaded?(_document), do: false

  defp add_processing_document(socket, document) do
    update(socket, :processing_docs, fn docs ->
      [document | Enum.reject(docs, &(&1.id == document.id))]
    end)
  end

  defp remove_processing_document(socket, document_id) do
    update(socket, :processing_docs, fn docs ->
      Enum.reject(docs, &(&1.id == document_id))
    end)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_processing_docs, @prune_interval_ms)
  end
end
