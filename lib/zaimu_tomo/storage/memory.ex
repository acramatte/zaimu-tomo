defmodule ZaimuTomo.Storage.Memory do
  @moduledoc false

  use GenServer

  @behaviour ZaimuTomo.Storage.Adapter

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])}
  end

  @impl true
  def put_object(key, body, _config) do
    :ets.insert(table(), {key, IO.iodata_to_binary(body)})
    {:ok, key}
  end

  @impl true
  def get_object(key, destination, _config) do
    case :ets.lookup(table(), key) do
      [{^key, body}] ->
        case File.write(destination, body) do
          :ok -> {:ok, destination}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def read_object(key, _config) do
    case :ets.lookup(table(), key) do
      [{^key, body}] -> {:ok, body}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete_object(key, _config) do
    :ets.delete(table(), key)
    :ok
  end

  @impl true
  def head_object(key, _config) do
    if :ets.member(table(), key), do: :ok, else: {:error, :not_found}
  end

  @doc false
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> GenServer.call(__MODULE__, :table)
      table -> table
    end
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, @table, state}
end
