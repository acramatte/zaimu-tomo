defmodule ZaimuTomoWeb.HealthController do
  use ZaimuTomoWeb, :controller

  def show(conn, _params) do
    text(conn, "OK")
  end
end
