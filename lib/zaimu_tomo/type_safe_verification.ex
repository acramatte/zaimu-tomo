defmodule ZaimuTomo.TypeSafeVerification do
  @moduledoc """
  Queues TypeSafe shadow-verification jobs and runs them with bounded concurrency.
  """

  use GenServer

  @default_max_concurrency 2
  @default_max_queue 100
  @default_retry_interval 1_000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(GenServer.server(), map()) ::
          :ok | {:error, :queue_full | :dispatcher_unavailable}
  def enqueue(server \\ __MODULE__, command) when is_map(command) do
    GenServer.call(server, {:enqueue, command})
  catch
    :exit, _reason -> {:error, :dispatcher_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       worker: Keyword.fetch!(opts, :worker),
       max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
       max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
       retry_interval: Keyword.get(opts, :retry_interval, @default_retry_interval),
       retry_timer: nil,
       running: %{},
       queued: :queue.new()
     }}
  end

  @impl true
  def handle_call({:enqueue, command}, _from, state) do
    if :queue.len(state.queued) >= state.max_queue do
      {:reply, {:error, :queue_full}, state}
    else
      state = state |> enqueue_command(command) |> start_available_jobs()
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    {:noreply,
     state |> update_in([:running], &Map.delete(&1, reference)) |> start_available_jobs()}
  end

  def handle_info(:retry_start, state) do
    {:noreply, state |> Map.put(:retry_timer, nil) |> start_available_jobs()}
  end

  defp enqueue_command(state, command) do
    update_in(state.queued, &:queue.in(command, &1))
  end

  defp start_available_jobs(%{running: running, max_concurrency: limit} = state)
       when map_size(running) >= limit,
       do: state

  defp start_available_jobs(state) do
    case :queue.peek(state.queued) do
      {:value, command} ->
        case start_task(state, command) do
          {:ok, pid} ->
            reference = Process.monitor(pid)

            state
            |> update_in([:queued], &:queue.drop/1)
            |> update_in([:running], &Map.put(&1, reference, pid))
            |> start_available_jobs()

          {:error, :task_supervisor_unavailable} ->
            schedule_retry(state)
        end

      :empty ->
        state
    end
  end

  defp start_task(state, command) do
    Task.Supervisor.start_child(state.task_supervisor, fn ->
      state.worker.perform(command)
    end)
  catch
    :exit, _reason -> {:error, :task_supervisor_unavailable}
  end

  defp schedule_retry(%{retry_timer: nil} = state) do
    timer = Process.send_after(self(), :retry_start, state.retry_interval)
    %{state | retry_timer: timer}
  end

  defp schedule_retry(state), do: state
end
