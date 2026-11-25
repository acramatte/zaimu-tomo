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

  test "schedule/2 works on a fresh socket without pre-assigning :refresh_timer" do
    socket = %Socket{transport_pid: self()}

    updated = ProcessingRefresh.schedule(socket, true)

    assert is_reference(updated.assigns.refresh_timer)
    assert_receive :refresh_processing, 200
  end

  test "schedule/2 does not schedule a second timer if one is already active" do
    socket = %Socket{transport_pid: self()}

    first = ProcessingRefresh.schedule(socket, true)
    second = ProcessingRefresh.schedule(first, true)

    assert second.assigns.refresh_timer == first.assigns.refresh_timer
    assert_receive :refresh_processing, 200
    refute_receive :refresh_processing, 80
  end

  test "schedule/2 does nothing when disconnected" do
    socket = %Socket{transport_pid: nil}

    updated = ProcessingRefresh.schedule(socket, true)

    assert updated == socket
    refute Map.has_key?(updated.assigns, :refresh_timer)
    refute_receive :refresh_processing, 80
  end

  test "schedule(socket, false) cancels an active timer and is a no-op without one" do
    idle = %Socket{transport_pid: self()}
    assert ProcessingRefresh.schedule(idle, false) == idle

    scheduled = ProcessingRefresh.schedule(idle, true)
    assert is_reference(scheduled.assigns.refresh_timer)

    cancelled = ProcessingRefresh.schedule(scheduled, false)
    assert cancelled.assigns.refresh_timer == nil
    refute_receive :refresh_processing, 80
  end

  test "clear/1 clears :refresh_timer so a subsequent schedule/2 schedules a fresh timer" do
    socket = %Socket{transport_pid: self()}

    first = ProcessingRefresh.schedule(socket, true)
    first_ref = first.assigns.refresh_timer
    assert_receive :refresh_processing, 200

    cleared = ProcessingRefresh.clear(first)
    assert cleared.assigns.refresh_timer == nil

    rescheduled = ProcessingRefresh.schedule(cleared, true)
    assert is_reference(rescheduled.assigns.refresh_timer)
    assert rescheduled.assigns.refresh_timer != first_ref
    assert_receive :refresh_processing, 200
  end
end
