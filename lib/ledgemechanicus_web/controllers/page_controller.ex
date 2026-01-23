defmodule LedgemechanicusWeb.PageController do
  use LedgemechanicusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
