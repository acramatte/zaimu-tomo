defmodule ZaimuTomoWeb.ProcessingRefresh do
  @moduledoc """
  Re-reads a LiveView while something on it is processing.

  A job broadcasts before Oban marks it complete, so the reload a broadcast
  triggers can still see the job running. While it does, `schedule/2` sends the
  view `:refresh_processing` after `:processing_refresh_interval_ms` (3 s by
  default). The view clears `refresh_timer` and reloads in its handler, and
  the reload calls `schedule/2` again, until nothing is processing.

  The socket must assign `refresh_timer: nil` in `mount/3`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @spec schedule(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def schedule(%{assigns: %{refresh_timer: nil}} = socket, true) do
    if connected?(socket) do
      interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
      assign(socket, :refresh_timer, Process.send_after(self(), :refresh_processing, interval))
    else
      socket
    end
  end

  def schedule(socket, _processing?), do: socket
end
