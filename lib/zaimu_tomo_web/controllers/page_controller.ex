defmodule ZaimuTomoWeb.PageController do
  use ZaimuTomoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
