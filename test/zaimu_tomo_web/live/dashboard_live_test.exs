defmodule ZaimuTomoWeb.DashboardLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the dashboard as a LiveView", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Good morning, there"
  end

  test "labels navigation items for the folded sidebar", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "class=\"nav-label\">Dashboard"
    assert html =~ "data-tooltip=\"Dashboard\""
    assert html =~ "aria-label=\"Dashboard\""
    assert html =~ "class=\"btn sm ghost sidebar-toggle\""
    assert html =~ "id=\"sidebar-toggle\""
  end
end
