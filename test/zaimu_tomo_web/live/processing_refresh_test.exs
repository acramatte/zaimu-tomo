defmodule ZaimuTomoWeb.ProcessingRefreshTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ZaimuTomoWeb.ProcessingRefresh

  setup do
    previous = Application.fetch_env(:zaimu_tomo, :processing_refresh_interval_ms)
    Application.put_env(:zaimu_tomo, :processing_refresh_interval_ms, 30)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaimu_tomo, :processing_refresh_interval_ms, value)
        :error -> Application.delete_env(:zaimu_tomo, :processing_refresh_interval_ms)
      end
    end)

    :ok
  end

  test "schedule/2 transitions a fresh socket from :idle to {:scheduled, ref}" do
    socket = %Socket{transport_pid: self()}
    assert ProcessingRefresh.state(socket) == :idle

    updated = ProcessingRefresh.schedule(socket, true)

    assert {:scheduled, ref} = ProcessingRefresh.state(updated)
    assert is_reference(ref)
    assert_receive :refresh_processing, 200
  end

  test "schedule/2 does not schedule a second timer if already scheduled" do
    socket = %Socket{transport_pid: self()}

    first = ProcessingRefresh.schedule(socket, true)
    second = ProcessingRefresh.schedule(first, true)

    assert ProcessingRefresh.state(second) == ProcessingRefresh.state(first)
    assert_receive :refresh_processing, 200
    refute_receive :refresh_processing, 80
  end

  test "schedule/2 stays :idle when disconnected" do
    socket = %Socket{transport_pid: nil}

    updated = ProcessingRefresh.schedule(socket, true)

    assert updated == socket
    assert ProcessingRefresh.state(updated) == :idle
    refute_receive :refresh_processing, 80
  end

  test "schedule(socket, false) cancels an active timer and is a no-op when :idle" do
    idle = %Socket{transport_pid: self()}
    assert ProcessingRefresh.schedule(idle, false) == idle

    scheduled = ProcessingRefresh.schedule(idle, true)
    assert {:scheduled, _ref} = ProcessingRefresh.state(scheduled)

    cancelled = ProcessingRefresh.schedule(scheduled, false)
    assert ProcessingRefresh.state(cancelled) == :idle
    refute_receive :refresh_processing, 80
  end

  test "on_tick/2 transitions back to :idle before reloading and lets reload reschedule" do
    socket = %Socket{transport_pid: self()}

    first = ProcessingRefresh.schedule(socket, true)
    {:scheduled, first_ref} = ProcessingRefresh.state(first)
    assert_receive :refresh_processing, 200

    rescheduled =
      ProcessingRefresh.on_tick(first, fn ticked ->
        assert ProcessingRefresh.state(ticked) == :idle
        ProcessingRefresh.schedule(ticked, true)
      end)

    assert {:scheduled, next_ref} = ProcessingRefresh.state(rescheduled)
    assert next_ref != first_ref
    assert_receive :refresh_processing, 200
  end

  test "on_tick/2 cancels a still-pending timer if invoked early" do
    socket = %Socket{transport_pid: self()}
    scheduled = ProcessingRefresh.schedule(socket, true)

    reloaded =
      ProcessingRefresh.on_tick(scheduled, fn ticked ->
        assert ProcessingRefresh.state(ticked) == :idle
        ticked
      end)

    assert ProcessingRefresh.state(reloaded) == :idle
    refute_receive :refresh_processing, 80
  end
end
