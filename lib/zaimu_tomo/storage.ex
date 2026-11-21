defmodule ZaimuTomo.Storage do
  @moduledoc """
  Provider-neutral document object storage facade.
  """

  alias ZaimuTomo.Fingerprint

  @type key :: String.t()

  @doc """
  Reads an uploaded file, stores its bytes under `<prefix>/<uuid>.<ext>`, and
  fingerprints them.

  The SHA-256 is computed over the exact binary passed to `put_object/2`, so
  the returned key and digest always describe the same bytes. The caller owns
  deleting the object if persisting its row fails.

  ## Examples

      iex> store_upload("/tmp/plug-123", "invoice.pdf", "documents")
      {:ok, %{object_key: "documents/….pdf", filename: "invoice.pdf", content_sha256: "…"}}

  """
  @spec store_upload(Path.t(), String.t(), String.t()) ::
          {:ok, %{object_key: key(), filename: String.t(), content_sha256: String.t()}}
          | {:error, term()}
  def store_upload(path, filename, prefix)
      when is_binary(path) and is_binary(filename) and is_binary(prefix) do
    object_key = "#{prefix}/#{Ecto.UUID.generate()}#{Path.extname(filename)}"

    with {:ok, body} <- File.read(path),
         content_sha256 = Fingerprint.sha256(body),
         {:ok, ^object_key} <- put_object(object_key, body) do
      {:ok, %{object_key: object_key, filename: filename, content_sha256: content_sha256}}
    else
      {:ok, _other_key} -> {:error, :unexpected_object_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_object(key(), iodata()) :: {:ok, key()} | {:error, term()}
  def put_object(key, body), do: adapter().put_object(key, body, config())

  @spec get_object(key(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def get_object(key, destination), do: adapter().get_object(key, destination, config())

  @spec delete_object(key()) :: :ok | {:error, term()}
  def delete_object(key), do: adapter().delete_object(key, config())

  @spec head_object(key()) :: :ok | {:error, :not_found | term()}
  def head_object(key), do: adapter().head_object(key, config())

  @doc """
  Reads an object fully into memory and returns its binary.

  Returns {:ok, binary} | {:error, :not_found | term()}
  """
  @spec read_object(key()) :: {:ok, binary()} | {:error, :not_found | term()}
  def read_object(key), do: adapter().read_object(key, config())

  defp adapter do
    config()
    |> Keyword.fetch!(:adapter)
  end

  defp config, do: Application.fetch_env!(:zaimu_tomo, :storage)
end
