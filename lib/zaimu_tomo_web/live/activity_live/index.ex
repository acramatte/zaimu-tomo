defmodule ZaimuTomoWeb.ActivityLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Activity
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents

  # Stalled documents need a retry, so they sit under Failed.
  @tabs [
    {"all", "All", :all},
    {"review", "Needs review", ["review"]},
    {"processing", "Processing", ["processing"]},
    {"failed", "Failed", ["failed", "stalled"]},
    {"posted", "Posted", ["posted"]},
    {"rejected", "Rejected", ["rejected"]}
  ]
  @tab_keys Enum.map(@tabs, &elem(&1, 0))

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      DocumentProcessing.subscribe_events(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "invoice_review:completed")
    end

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:tabs, @tabs)
     |> assign(:tab, "all")
     |> assign(:refresh_timer, nil)
     |> load_activity()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tab_keys, do: params["tab"], else: "all"
    {:noreply, socket |> assign(:tab, tab) |> assign_visible()}
  end

  @impl true
  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted],
      do: {:noreply, load_activity(socket)}

  def handle_info(%{user_id: user_id}, socket)
      when user_id == socket.assigns.current_scope.user.id,
      do: {:noreply, load_activity(socket)}

  def handle_info(:refresh_processing, socket),
    do: {:noreply, socket |> assign(:refresh_timer, nil) |> load_activity()}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_activity(socket) do
    items = Activity.list_recent(socket.assigns.current_scope, limit: :all)

    counts =
      Map.new(@tabs, fn {key, _label, statuses} ->
        {key, Enum.count(items, &in_tab?(&1, statuses))}
      end)

    socket
    |> assign(:activity_items, items)
    |> assign(:counts, counts)
    |> assign_visible()
    |> schedule_refresh(counts["processing"] > 0)
  end

  # The worker broadcasts before Oban acknowledges the job, so the reload a
  # broadcast triggers can still see the job running. While anything is
  # processing, re-read the durable state until it settles.
  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket, true) do
    if connected?(socket) do
      interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
      assign(socket, :refresh_timer, Process.send_after(self(), :refresh_processing, interval))
    else
      socket
    end
  end

  defp schedule_refresh(socket, _processing?), do: socket

  defp assign_visible(socket) do
    {_key, _label, statuses} = List.keyfind!(@tabs, socket.assigns.tab, 0)
    assign(socket, :items, Enum.filter(socket.assigns.activity_items, &in_tab?(&1, statuses)))
  end

  defp in_tab?(_item, :all), do: true
  defp in_tab?(item, statuses), do: item.status in statuses

  defp tab_path("all"), do: ~p"/activity"
  defp tab_path(tab), do: ~p"/activity?tab=#{tab}"
end
