defmodule ZaimuTomoWeb.DocumentLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents

  @prune_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      DocumentProcessing.subscribe_events(socket.assigns.current_scope)
      schedule_prune()
    end

    {:ok,
     socket
     |> assign(:page_title, "Documents")
     |> assign(:current_path, "/documents")
     |> assign(:preview_id, nil)
     |> assign(:preview_doc, nil)
     |> refresh_documents()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    preview_id = params["preview"]

    socket =
      case preview_id do
        nil ->
          assign(socket, preview_id: nil, preview_doc: nil)

        id ->
          # Do not read storage here; only resolve the document metadata so the UI can
          # render an iframe/img that will fetch the proxied binary when the browser
          # requests it.
          document = Documents.get_document!(socket.assigns.current_scope, id)
          assign(socket, preview_id: document.id, preview_doc: document)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="view-title">Documents</h1>
    <p class="view-sub">All uploaded receipts, invoices, and pay stubs</p>

    <.processing_hero documents={@processing_docs} />

    <div class="card">
      <div class="card-head">
        <div class="card-title">All files</div>
      </div>
      {live_render(@socket, ZaimuTomoWeb.DocumentUploadLive, id: "doc-upload")}
      <div class="feed" id="documents-feed" phx-update="stream" style="margin-top:16px">
        <div
          :for={{dom_id, %{document: document, state: state}} <- @streams.documents}
          id={dom_id}
          class={"feed-item #{row_status(state, List.first(document.extracted_content))}"}
        >
          <% ec = List.first(document.extracted_content) %>
          <% status = row_status(state, ec) %>
          <% data = ec && ec.extracted_data %>
          <% ext =
            document.filename
            |> Path.extname()
            |> String.trim_leading(".")
            |> String.upcase()
            |> String.slice(0, 3) %>
          <.link
            patch={~p"/documents?preview=#{document.id}"}
            class="row-preview-link"
            aria-label="Preview document"
            title="Preview"
          >
            <div class="stat">{if ext == "", do: "DOC", else: ext}</div>
            <div class="body">
              <div class="title">
                {(data && data.issuer) || document.filename}
                <.status_pill status={if status == "stalled", do: "Processing stalled", else: status} />
              </div>
              <div class="desc">
                <%= case status do %>
                  <% "processing" -> %>
                    Sent to OCR · extraction in progress
                    <%= if ec && ec.status == "failed" do %>
                      · previous attempt failed: {get_in(ec.error_details || %{}, ["message"]) ||
                        "Processing failed"}
                    <% end %>
                  <% "stalled" -> %>
                    Processing stalled · no OCR run is active, open to retry
                  <% "review" -> %>
                    <span class="amt">
                      {if data && data.amount_to_pay_cents && data.currency,
                        do: fmt_cents(data.amount_to_pay_cents, data.currency),
                        else: "—"}
                    </span>
                    {if data && data.invoice_number, do: " · #{data.invoice_number}", else: ""} · ready to verify
                  <% "failed" -> %>
                    {(ec && get_in(ec.error_details || %{}, ["message"])) || "Processing failed"}
                  <% _ -> %>
                    {document.filename}
                <% end %>
                · <span class="muted">{document.filename}</span>
              </div>
            </div>
          </.link>
          <div class="actions">
            <div class="row-actions">
              <a
                :if={status == "review" && ec && ec.review_decision}
                class="btn sm primary"
                href={~p"/reviews/#{ec.review_decision}"}
              >
                Review
              </a>
              <.link
                :if={status != "posted"}
                navigate={~p"/documents/#{document}/edit"}
                class="icon-btn"
                aria-label="Edit document"
                title="Edit"
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" />
              </.link>
              <a
                class="icon-btn"
                href={~p"/documents/#{document}/download"}
                aria-label="Download document"
                title="Download"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              </a>
              <.link
                phx-click={JS.push("delete", value: %{id: document.id}) |> hide("##{dom_id}")}
                data-confirm="Are you sure?"
                class="icon-btn icon-btn-danger"
                aria-label="Delete document"
                title="Delete"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </.link>
            </div>
            <div>
              <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(document.inserted_at))}</time>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%= if @preview_doc do %>
      <div
        class="modal-bg show"
        id="document-preview"
        phx-click-away="close-preview"
        phx-window-keydown="close-preview"
        phx-key="Escape"
      >
        <div class="doc-modal">
          <header>
            <h3>{@preview_doc.filename}</h3>
            <a class="btn sm" href={~p"/documents/#{@preview_doc}/download"}>Download</a>
            <.link
              patch={~p"/documents"}
              class="icon-btn modal-close"
              aria-label="Close preview"
              title="Close"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </.link>
          </header>
          <div class="doc-modal-body">
            <%= case ZaimuTomo.MediaPreview.previewable?(MIME.from_path(@preview_doc.filename), Path.extname(@preview_doc.filename)) do %>
              <% {:ok, :pdf} -> %>
                <iframe
                  src={~p"/documents/#{@preview_doc}/preview"}
                  title={"Preview of #{@preview_doc.filename}"}
                ></iframe>
              <% {:ok, :image} -> %>
                <div class="doc-modal-image">
                  <img
                    src={~p"/documents/#{@preview_doc}/preview"}
                    alt={@preview_doc.filename}
                  />
                </div>
              <% {:error, :not_previewable} -> %>
                <div class="doc-modal-empty">
                  <div class="view-sub">Inline preview not available for this file type.</div>
                  <a class="btn" href={~p"/documents/#{@preview_doc}/download"}>Download</a>
                </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @impl true
  def handle_event("close-preview", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/documents")}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    document = Documents.get_document!(socket.assigns.current_scope, id)

    case Documents.delete_document(socket.assigns.current_scope, document) do
      {:ok, _} ->
        {:noreply, stream_delete(socket, :documents, document)}

      {:error, changeset} ->
        msg = changeset.errors[:id] |> elem(0)
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_info({:document_uploaded, _document}, socket) do
    {:noreply, refresh_documents(socket)}
  end

  def handle_info(%{document_id: _id, user_id: uid}, socket)
      when uid == socket.assigns.current_scope.user.id do
    {:noreply, refresh_documents(socket)}
  end

  def handle_info(:prune_processing_docs, socket) do
    schedule_prune()
    {:noreply, refresh_documents(socket)}
  end

  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, refresh_documents(socket)}
  end

  defp derive_status(nil), do: "processing"
  defp derive_status(%{status: "failed"}), do: "failed"

  defp derive_status(%{review_decision: %{review_status: s}}) when s in ["approved", "amended"],
    do: "posted"

  defp derive_status(%{review_decision: %{review_status: "rejected"}}), do: "failed"
  defp derive_status(_), do: "review"

  # Row status from the durable processing state, falling back to the latest
  # extraction (review decision) once a run has completed.
  defp row_status(:processing, _ec), do: "processing"
  defp row_status(:stuck, _ec), do: "stalled"
  defp row_status(:failed, _ec), do: "failed"
  defp row_status(:extracted, ec), do: derive_status(ec)

  # Loads the documents with their durable processing state (two batched
  # queries, independent of the row count) and resets the stream and hero.
  defp refresh_documents(socket) do
    documents = Documents.list_documents(socket.assigns.current_scope)
    states = DocumentProcessing.processing_states(Enum.map(documents, & &1.id))
    rows = Enum.map(documents, &%{id: &1.id, document: &1, state: states[&1.id]})

    socket
    |> assign(:processing_docs, Enum.filter(documents, &(states[&1.id] == :processing)))
    |> stream(:documents, rows, reset: true)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_processing_docs, @prune_interval_ms)
  end
end
