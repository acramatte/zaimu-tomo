defmodule ZaimuTomo.Storage do
  @moduledoc """
  Provider-neutral document object storage facade.
  """

  @type key :: String.t()

  @spec put_object(key(), iodata()) :: {:ok, key()} | {:error, term()}
  def put_object(key, body), do: adapter().put_object(key, body, config())

  @spec get_object(key(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def get_object(key, destination), do: adapter().get_object(key, destination, config())

  @spec delete_object(key()) :: :ok | {:error, term()}
  def delete_object(key), do: adapter().delete_object(key, config())

  @spec head_object(key()) :: :ok | {:error, :not_found | term()}
  def head_object(key), do: adapter().head_object(key, config())

  defp adapter do
    config()
    |> Keyword.fetch!(:adapter)
  end

  defp config, do: Application.fetch_env!(:zaimu_tomo, :storage)
end
