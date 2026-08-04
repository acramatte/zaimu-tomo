defmodule ZaimuTomoWeb.RecentActivityLive do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Activity
  alias ZaimuTomo.Documents

  on_mount {ZaimuTomoWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "invoice_review:completed")
    end

    {:ok, assign_activity(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@activity == []} id="dashboard-recent-activity-empty" class="empty-state">
      <div class="h">No activity yet</div>
      <div class="muted">Upload a receipt or invoice to start your activity feed.</div>
    </div>
    <div :if={@activity != []} id="dashboard-recent-activity" class="feed">
      <.feed_item :for={item <- @activity} item={item} />
    </div>
    """
  end

  @impl true
  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted],
      do: {:noreply, assign_activity(socket)}

  def handle_info(%{user_id: user_id}, socket)
      when user_id == socket.assigns.current_scope.user.id,
      do: {:noreply, assign_activity(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_activity(socket) do
    assign(socket, :activity, Activity.list_recent(socket.assigns.current_scope, limit: 5))
  end
end
