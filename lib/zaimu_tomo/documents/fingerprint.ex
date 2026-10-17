defmodule ZaimuTomo.Documents.Fingerprint do
  @moduledoc """
  Exact-byte SHA-256 fingerprint of an uploaded document.

  The digest identifies byte-identical files only. It is never derived from
  OCR or LLM output, and it must not be logged, rendered, or sent to an AI
  provider.
  """

  @format ~r/\A[0-9a-f]{64}\z/

  @doc """
  Returns the SHA-256 of `bytes` as 64 lowercase hexadecimal characters.

      iex> ZaimuTomo.Documents.Fingerprint.sha256("")
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  """
  @spec sha256(iodata()) :: String.t()
  def sha256(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  @doc "Regex every stored fingerprint must match."
  @spec format() :: Regex.t()
  def format, do: @format
end
