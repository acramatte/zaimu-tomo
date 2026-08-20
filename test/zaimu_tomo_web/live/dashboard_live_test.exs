defmodule ZaimuTomoWeb.DashboardLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the dashboard as a LiveView", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Good morning, there"
  end
end
