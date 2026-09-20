defmodule ZaimuTomo.TypeSafeVerificationTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.TypeSafeVerification

  defmodule TestWorker do
    def perform(%{test_pid: test_pid, id: id}) do
      send(test_pid, {:started, id, self()})

      receive do
        :release -> send(test_pid, {:finished, id})
      end
    end
  end

  test "queues work once the configured concurrency limit is reached" do
    task_supervisor_name = unique_name(:tasks)
    start_supervised!({Task.Supervisor, name: task_supervisor_name})
    dispatcher_name = unique_name(:dispatcher)

    start_supervised!(
      {TypeSafeVerification,
       name: dispatcher_name,
       task_supervisor: task_supervisor_name,
       worker: TestWorker,
       max_concurrency: 1,
       max_queue: 1}
    )

    assert :ok = TypeSafeVerification.enqueue(dispatcher_name, %{test_pid: self(), id: 1})
    assert :ok = TypeSafeVerification.enqueue(dispatcher_name, %{test_pid: self(), id: 2})

    assert {:error, :queue_full} =
             TypeSafeVerification.enqueue(dispatcher_name, %{test_pid: self(), id: 3})

    assert_receive {:started, 1, first_pid}
    refute_receive {:started, 2, _pid}, 50

    send(first_pid, :release)

    assert_receive {:finished, 1}
    assert_receive {:started, 2, second_pid}
    send(second_pid, :release)
    assert_receive {:finished, 2}
    refute_receive {:started, 3, _pid}
  end

  test "retains queued work while the task supervisor is temporarily unavailable" do
    task_supervisor_name = unique_name(:delayed_tasks)
    dispatcher_name = unique_name(:delayed_dispatcher)

    start_supervised!(
      {TypeSafeVerification,
       name: dispatcher_name,
       task_supervisor: task_supervisor_name,
       worker: TestWorker,
       max_concurrency: 1,
       retry_interval: 10}
    )

    assert :ok = TypeSafeVerification.enqueue(dispatcher_name, %{test_pid: self(), id: 1})
    refute_receive {:started, 1, _pid}, 20

    start_supervised!({Task.Supervisor, name: task_supervisor_name})

    assert_receive {:started, 1, worker_pid}, 200
    send(worker_pid, :release)
    assert_receive {:finished, 1}
  end

  test "reports an unavailable dispatcher instead of silently dropping work" do
    assert {:error, :dispatcher_unavailable} =
             TypeSafeVerification.enqueue(unique_name(:missing), %{id: 1})
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")
end
