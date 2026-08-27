defmodule ZaimuTomoWeb.DocumentController do
  use ZaimuTomoWeb, :controller

  require Logger

  alias ZaimuTomo.Documents
  alias ZaimuTomo.MediaPreview
  alias ZaimuTomo.Storage

  @generic_unavailable_msg "Service unavailable"

  def preview(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, document} <- Documents.fetch_document(scope, id),
         {:ok, mime, ext} <- preview_media(document) do
      send_preview(conn, document, mime, ext)
    else
      {:error, :not_found} -> send_resp(conn, 404, "Not found")
      {:error, :not_previewable} -> send_resp(conn, 415, "Preview not available for this file type")
    end
  end

  def download(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, document} <- Documents.fetch_document(scope, id) do
      send_download_response(conn, document)
    else
      {:error, :not_found} -> send_resp(conn, 404, "Not found")
    end
  end

  # Object reads are bounded by the upload limit (20MB) and load the whole
  # document into memory. Stream to the response instead if that limit grows.
  defp preview_media(document) do
    mime = MIME.from_path(document.filename)
    ext = Path.extname(document.filename)

    case MediaPreview.previewable?(mime, ext) do
      {:ok, _kind} -> {:ok, mime, ext}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_preview(conn, document, mime, ext) do
    case Storage.read_object(document.object_key) do
      {:ok, binary} ->
        conn
        |> put_preview_headers()
        |> put_resp_content_type(MediaPreview.safe_content_type(mime, ext))
        |> put_resp_header("content-disposition", "inline")
        |> send_resp(200, binary)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, reason} ->
        Logger.error("Document preview failed for id=#{document.id}: #{inspect(reason)}")
        send_resp(conn, 503, @generic_unavailable_msg)
    end
  end

  defp send_download_response(conn, document) do
    case Storage.read_object(document.object_key) do
      {:ok, binary} ->
        filename = MediaPreview.safe_download_filename(document.filename)
        mime = MIME.from_path(document.filename)
        ext = Path.extname(document.filename)

        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:binary, binary},
          filename: filename,
          content_type: MediaPreview.safe_content_type(mime, ext)
        )

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, reason} ->
        Logger.error("Document download failed for id=#{document.id}: #{inspect(reason)}")
        send_resp(conn, 503, @generic_unavailable_msg)
    end
  end

  defp put_preview_headers(conn) do
    conn
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "frame-ancestors 'self'")
  end
end
