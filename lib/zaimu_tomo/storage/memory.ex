defmodule ZaimuTomo.Storage.Memory do
  @moduledoc false

  @behaviour ZaimuTomo.Storage.Adapter

  @table __MODULE__

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
      :undefined -> create_table()
      table -> table
    end
  end

  defp create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> @table
  end
end
