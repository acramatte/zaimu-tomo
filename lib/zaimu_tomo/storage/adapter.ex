defmodule ZaimuTomo.Storage.Adapter do
  @moduledoc """
  Contract implemented by document object storage providers.
  """

  @type key :: String.t()
  @type config :: keyword()

  @callback put_object(key(), iodata(), config()) :: {:ok, key()} | {:error, term()}
  @callback get_object(key(), Path.t(), config()) :: {:ok, Path.t()} | {:error, term()}
  @callback delete_object(key(), config()) :: :ok | {:error, term()}
  @callback head_object(key(), config()) :: :ok | {:error, :not_found | term()}
end
