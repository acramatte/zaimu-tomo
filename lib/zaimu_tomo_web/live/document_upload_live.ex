defmodule ZaimuTomoWeb.DocumentUploadLive do
  use ZaimuTomoWeb, :live_view

  on_mount {ZaimuTomoWeb.UserAuth, :require_authenticated}

  alias ZaimuTomo.Documents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     allow_upload(socket, :document,
       accept: ~w(.jpg .jpeg .png .tiff .heic .heif .webp .pdf .docx .odt .txt),
       max_file_size: 20_000_000,
       auto_upload: true,
       chunk_size: 64_000 * 3,
       max_entries: 5
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="doc-upload-form" phx-change="validate" phx-submit="save" phx-hook=".AutoSave">
      <div class="drop-zone" phx-drop-target={@uploads.document.ref}>
        <label for={@uploads.document.ref} style="cursor:pointer;display:block">
          <.live_file_input upload={@uploads.document} style="display:none" />
          <div class="glyph">+</div>
          <div class="h">Drop an invoice or receipt</div>
          <div class="sub">
            PDF, JPG, HEIC · sent to OCR · review takes <span class="kbd">~30s</span>
          </div>
          <div class="sub" style="margin-top:10px">
            or paste with <span class="kbd">⌘V</span>
            · click to <span class="kbd">browse</span>
          </div>
        </label>
      </div>

      <div :if={@uploads.document.entries != []} style="margin-top:10px">
        <div
          :for={entry <- @uploads.document.entries}
          style="display:flex;align-items:center;gap:8px;font-size:12px;padding:6px 0"
        >
          <span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
            {entry.client_name}
          </span>
          <progress value={entry.progress} max="100" style="width:80px" />
          <span class="muted">{entry.progress}%</span>
          <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref}>×</button>
          <p
            :for={err <- upload_errors(@uploads.document, entry)}
            role="alert"
            style="color:var(--danger);font-size:11.5px"
          >
            {error_to_string(err)}
          </p>
        </div>
      </div>
    </form>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoSave">
      export default {
        mounted() {
          this._sent = false
          this._timer = setInterval(() => this._check(), 250)
          this._check()
        },
        updated() { this._check() },
        destroyed() { clearInterval(this._timer) },
        _check() {
          const bars = [...this.el.querySelectorAll("progress")]
          if (bars.length === 0) { this._sent = false; return }
          if (this._sent) return
          if (bars.every(b => b.value >= b.max)) {
            this._sent = true
            this.pushEvent("save", {})
          }
        }
      }
    </script>
    """
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    {:noreply, consume_done(socket)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :document, ref)}
  end

  defp consume_done(socket) do
    {done, in_progress} = uploaded_entries(socket, :document)

    if done == [] or in_progress != [] do
      socket
    else
      do_consume(socket)
    end
  end

  defp do_consume(socket) do
    scope = socket.assigns.current_scope

    entries =
      consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
        unique_name = "#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}"
        dest = Path.join([:code.priv_dir(:zaimu_tomo), "uploads", unique_name])
        File.cp!(path, dest)
        {:ok, %{filepath: Path.join(["/", "uploads", unique_name]), client_name: entry.client_name}}
      end)

    Enum.reduce(entries, socket, fn saved, sock ->
      case Documents.create_document(scope, %{
             "filepath" => saved.filepath,
             "filename" => saved.client_name
           }) do
        {:ok, document} ->
          if sock.parent_pid, do: send(sock.parent_pid, {:document_uploaded, document})
          push_event(sock, "upload:success", %{filename: document.filename})

        {:error, _} ->
          sock
      end
    end)
  end

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "Too many files"
  defp error_to_string(:not_accepted), do: "Unsupported file type"
end
