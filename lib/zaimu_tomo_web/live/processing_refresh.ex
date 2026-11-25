defmodule ZaimuTomoWeb.ProcessingRefresh do
  @moduledoc """
  Re-reads a LiveView while something on it is processing.

  A job broadcasts before Oban marks it complete, so the reload a broadcast
  triggers can still see the job running. While it does, `schedule/2`
  transitions the socket's refresh state from `:idle` to `{:scheduled, ref}`
  and sends `:refresh_processing` after `:processing_refresh_interval_ms` (3 s
  by default). In its `:refresh_processing` handler, the view calls
  `on_tick(socket, &reload/1)`, which transitions back to `:idle` before
  running the reload; the reload calls `schedule/2` again until nothing is
  processing (`schedule(socket, false)` cancels any active timer and returns
  to `:idle`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @type state :: :idle | {:scheduled, reference()}

  @doc """
  Schedules or cancels the `:refresh_processing` timer based on whether work is
  still processing.
  """
  @spec schedule(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def schedule(socket, true) do
    case state(socket) do
      :idle ->
        if connected?(socket) do
          interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
          ref = Process.send_after(self(), :refresh_processing, interval)
          assign(socket, :processing_refresh, {:scheduled, ref})
        else
          socket
        end

      {:scheduled, _ref} ->
        socket
    end
  end

  def schedule(socket, false) do
    case state(socket) do
      {:scheduled, ref} ->
        Process.cancel_timer(ref)
        assign(socket, :processing_refresh, :idle)

      :idle ->
        socket
    end
  end

  @doc """
  Handles a `:refresh_processing` tick by transitioning the timer state back to
  `:idle` (canceling any still-pending timer) and running `reload_fun`.
  """
  @spec on_tick(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def on_tick(socket, reload_fun) when is_function(reload_fun, 1) do
    socket
    |> schedule(false)
    |> reload_fun.()
  end

  @doc "Returns the current refresh timer state (`:idle` or `{:scheduled, ref}`)."
  @spec state(Phoenix.LiveView.Socket.t()) :: state()
  def state(socket), do: Map.get(socket.assigns, :processing_refresh, :idle)
end
