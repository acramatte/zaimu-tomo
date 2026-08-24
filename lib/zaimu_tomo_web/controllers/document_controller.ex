defmodule ZaimuTomoWeb.DocumentController do
  use ZaimuTomoWeb, :controller

  alias ZaimuTomo.Storage
  alias ZaimuTomo.MediaPreview

  def preview(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    # resolve the document within the authenticated scope without raising
    alias ZaimuTomo.Documents.Document
    alias ZaimuTomo.Repo

    case Repo.get_by(Document, id: id, user_id: scope.user.id) do
      nil ->
        conn |> send_resp(404, "Not found") |> halt()

      document ->
        mime = MIME.from_path(document.filename)
        ext = Path.extname(document.filename)

        case MediaPreview.previewable?(mime, ext) do
          {:ok, _kind} ->
            case Storage.read_object(document.object_key) do
              {:ok, binary} ->
                conn
                |> put_resp_header("x-frame-options", "SAMEORIGIN")
                |> put_resp_header("x-content-type-options", "nosniff")
                |> put_resp_header("content-security-policy", "frame-ancestors 'self'")
                |> put_resp_content_type(MediaPreview.safe_content_type(mime, ext))
                |> put_resp_header("content-disposition", "inline")
                |> send_resp(200, binary)

              {:error, :not_found} ->
                send_resp(conn, 404, "Not found")

              {:error, reason} ->
                send_resp(conn, 503, "Unavailable: #{inspect(reason)}")
            end

          {:error, :not_previewable} ->
            send_resp(conn, 415, "Preview not available for this file type")
        end
    end
  end

  def download(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    # resolve the document within the authenticated scope without raising
    alias ZaimuTomo.Documents.Document
    alias ZaimuTomo.Repo

    case Repo.get_by(Document, id: id, user_id: scope.user.id) do
      nil ->
        conn |> send_resp(404, "Not found") |> halt()

      document ->
        mime = MIME.from_path(document.filename)
        ext = Path.extname(document.filename)

        case Storage.read_object(document.object_key) do
          {:ok, binary} ->
            filename = MediaPreview.safe_download_filename(document.filename)

            conn
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_content_type(MediaPreview.safe_content_type(mime, ext))
            |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
            |> send_resp(200, binary)

          {:error, :not_found} ->
            send_resp(conn, 404, "Not found")

          {:error, reason} ->
            send_resp(conn, 503, "Unavailable: #{inspect(reason)}")
        end
    end
  end
end
