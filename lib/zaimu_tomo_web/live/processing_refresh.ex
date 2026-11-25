defmodule ZaimuTomoWeb.ProcessingRefresh do
  @moduledoc """
  Re-reads a LiveView while something on it is processing.

  A job broadcasts before Oban marks it complete, so the reload a broadcast
  triggers can still see the job running. While it does, `schedule/2` sends the
  view `:refresh_processing` after `:processing_refresh_interval_ms` (3 s by
  default). The view calls `clear/1` and reloads in its `:refresh_processing`
  handler, and the reload calls `schedule/2` again, until nothing is processing
  (at which point `schedule(socket, false)` cancels any active timer).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @doc """
  Schedules or cancels the `:refresh_processing` timer based on whether work is
  still processing.
  """
  @spec schedule(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def schedule(socket, true) do
    if is_nil(Map.get(socket.assigns, :refresh_timer)) and connected?(socket) do
      interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
      assign(socket, :refresh_timer, Process.send_after(self(), :refresh_processing, interval))
    else
      socket
    end
  end

  def schedule(socket, false) do
    case Map.get(socket.assigns, :refresh_timer) do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        assign(socket, :refresh_timer, nil)

      _other ->
        socket
    end
  end

  @doc """
  Clears the active `:refresh_timer` assign after `:refresh_processing` fires.
  """
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: assign(socket, :refresh_timer, nil)
end
