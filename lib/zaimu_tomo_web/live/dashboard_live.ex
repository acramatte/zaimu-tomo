defmodule ZaimuTomoWeb.DashboardLive do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomoWeb.PageController
  alias ZaimuTomoWeb.PageHTML

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, PageController.dashboard_assigns(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns), do: PageHTML.home(assigns)
end
