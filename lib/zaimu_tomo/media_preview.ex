defmodule ZaimuTomo.MediaPreview do
  @moduledoc """
  Policy for document preview and media handling.

  Exposes helper functions to decide whether a stored object may be previewed inline
  (by the browser) and what kind of preview to render.
  """

  @preview_image_types ~w(image/jpeg image/png image/webp)
  @preview_pdf "application/pdf"

  @no_inline_exts ~w(heic heif tiff tif docx odt txt)

  @spec previewable?(String.t() | nil, String.t() | nil) ::
          {:ok, :pdf | :image} | {:error, :not_previewable}
  def previewable?(mime, ext) do
    mime = mime || ""
    ext = (ext || "") |> String.trim_leading(".") |> String.downcase()

    cond do
      mime == @preview_pdf -> {:ok, :pdf}
      mime in @preview_image_types -> {:ok, :image}
      ext in @no_inline_exts -> {:error, :not_previewable}
      true -> {:error, :not_previewable}
    end
  end

  @spec safe_content_type(String.t() | nil, String.t() | nil) :: String.t()
  def safe_content_type(mime, _ext) when is_binary(mime) and mime != "", do: mime

  def safe_content_type(_mime, ext) when is_binary(ext) do
    case ext |> String.trim_leading(".") |> String.downcase() do
      "pdf" -> @preview_pdf
      "jpg" -> "image/jpeg"
      "jpeg" -> "image/jpeg"
      "png" -> "image/png"
      "webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  @spec safe_download_filename(String.t()) :: String.t()
  def safe_download_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r{["'\\/\s]+}, "_")
  end
end
