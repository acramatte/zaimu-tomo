defmodule ZaimuTomoWeb.DocumentLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Documents

  @processing_window_seconds 10 * 60
  @prune_interval_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")
      schedule_prune()
    end

    documents = Documents.list_documents(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Documents")
     |> assign(:current_path, "/documents")
     |> assign(:processing_docs, processing_documents(documents))
     |> assign(:preview_id, nil)
     |> assign(:preview_doc, nil)
     |> stream(:documents, documents)}
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
          :for={{dom_id, document} <- @streams.documents}
          id={dom_id}
          class={"feed-item #{derive_status(List.first(document.extracted_content))}"}
        >
          <% ec = List.first(document.extracted_content) %>
          <% status = derive_status(ec) %>
          <% data = ec && ec.extracted_data %>
          <% ext =
            document.filename
            |> Path.extname()
            |> String.trim_leading(".")
            |> String.upcase()
            |> String.slice(0, 3) %>
          <div class="stat">{if ext == "", do: "DOC", else: ext}</div>
          <div class="body">
            <div class="title">
              {(data && data.issuer) || document.filename}
              <.status_pill status={status} />
            </div>
            <div class="desc">
              <%= case status do %>
                <% "processing" -> %>
                  Sent to OCR · extraction in progress
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
          <div class="actions">
            <div>
              <a
                :if={status == "review" && ec && ec.review_decision}
                class="btn sm primary"
                href={~p"/reviews/#{ec.review_decision}"}
              >
                Review
              </a>
              <.link :if={status != "posted"} navigate={~p"/documents/#{document}/edit"}>Edit</.link>
              <.link
                phx-click={JS.push("delete", value: %{id: document.id}) |> hide("##{dom_id}")}
                data-confirm="Are you sure?"
              >
                Delete
              </.link>
              <.link patch={~p"/documents?preview=#{document.id}"} class="btn sm">Preview</.link>
              <a class="btn sm" href={~p"/documents/#{document}/download"}>Download</a>
            </div>
            <div>
              <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(document.inserted_at))}</time>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%= if @preview_doc do %>
      <div class="card doc-preview" style="margin-top:16px">
        <%= case ZaimuTomo.MediaPreview.previewable?(MIME.from_path(@preview_doc.filename), Path.extname(@preview_doc.filename)) do %>
          <% {:ok, :pdf} -> %>
            <iframe
              src={~p"/documents/#{@preview_doc}/preview"}
              style="width:100%;min-height:600px;border:0"
            >
            </iframe>
          <% {:ok, :image} -> %>
            <img
              src={~p"/documents/#{@preview_doc}/preview"}
              alt={@preview_doc.filename}
              style="max-width:100%;height:auto"
            />
          <% {:error, :not_previewable} -> %>
            <div style="text-align:center;padding:40px">
              <div class="view-sub">Inline preview not available for this file type.</div>
              <a class="btn" href={~p"/documents/#{@preview_doc}/download"}>Download</a>
            </div>
        <% end %>
      </div>
    <% end %>
    """
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
  def handle_info({:document_uploaded, document}, socket) do
    {:noreply,
     socket
     |> add_processing_document(document)
     |> stream(:documents, Documents.list_documents(socket.assigns.current_scope), reset: true)}
  end

  def handle_info({:created, %ZaimuTomo.Documents.Document{} = document}, socket) do
    {:noreply,
     socket
     |> add_processing_document(document)
     |> stream(:documents, Documents.list_documents(socket.assigns.current_scope), reset: true)}
  end

  def handle_info(%{document_id: id, user_id: uid}, socket)
      when uid == socket.assigns.current_scope.user.id do
    documents = Documents.list_documents(socket.assigns.current_scope)

    {:noreply,
     socket
     |> update(:processing_docs, fn docs -> Enum.reject(docs, &(&1.id == id)) end)
     |> assign(:processing_docs, processing_documents(documents))
     |> stream(:documents, documents, reset: true)}
  end

  def handle_info(:prune_processing_docs, socket) do
    schedule_prune()
    documents = Documents.list_documents(socket.assigns.current_scope)

    {:noreply, assign(socket, :processing_docs, processing_documents(documents))}
  end

  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(socket, :documents, Documents.list_documents(socket.assigns.current_scope),
       reset: true
     )}
  end

  defp derive_status(nil), do: "processing"
  defp derive_status(%{status: "failed"}), do: "failed"

  defp derive_status(%{review_decision: %{review_status: s}}) when s in ["approved", "amended"],
    do: "posted"

  defp derive_status(%{review_decision: %{review_status: "rejected"}}), do: "failed"
  defp derive_status(_), do: "review"

  defp add_processing_document(socket, document) do
    update(socket, :processing_docs, fn docs ->
      [document | Enum.reject(docs, &(&1.id == document.id))]
    end)
  end

  defp processing_documents(documents) do
    Enum.filter(documents, &processing_document?/1)
  end

  defp processing_document?(document) do
    derive_status(List.first(document.extracted_content)) == "processing" and
      recently_uploaded?(document)
  end

  defp recently_uploaded?(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) <= @processing_window_seconds
  end

  defp recently_uploaded?(_document), do: false

  defp schedule_prune do
    Process.send_after(self(), :prune_processing_docs, @prune_interval_ms)
  end
end
