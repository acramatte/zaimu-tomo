defmodule ZaimuTomoWeb.DocumentLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision

  @prune_interval_ms 30_000

  @tabs %{
    "needs_action" => "Needs action",
    "posted" => "Posted",
    "rejected" => "Rejected",
    "all" => "All"
  }
  @tab_order ~w(needs_action posted rejected all)

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
     |> assign(:tab, nil)
     |> assign(:processing_docs, [])
     |> stream(:documents, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    preview_id = params["preview"]
    tab = if params["tab"] in Map.keys(@tabs), do: params["tab"], else: "all"

    # The first call (right after mount) loads the rows for the requested
    # tab, so the stream is filled exactly once before the first render.
    socket =
      if tab != socket.assigns.tab,
        do: socket |> assign(:tab, tab) |> refresh_documents(),
        else: socket

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
    <p class="view-sub">Upload an invoice, then check and post it from its page</p>

    <nav class="invoice-tabs" id="document-tabs" aria-label="Filter documents">
      <.link
        :for={{key, label} <- @tab_list}
        patch={if key == "all", do: ~p"/documents", else: ~p"/documents?tab=#{key}"}
        class={["invoice-tab", @tab == key && "active"]}
        aria-current={if @tab == key, do: "page"}
      >
        {label} <span class="count">{@tab_counts[key]}</span>
      </.link>
    </nav>

    <.processing_hero documents={@processing_docs} />

    <div class="card">
      <div class="card-head">
        <div class="card-title">{@tabs[@tab]}</div>
      </div>
      {live_render(@socket, ZaimuTomoWeb.DocumentUploadLive, id: "doc-upload")}
      <div class="feed" id="documents-feed" phx-update="stream" style="margin-top:16px">
        <div
          :for={{dom_id, %{document: document, state: state, run: run}} <- @streams.documents}
          id={dom_id}
          class={"feed-item #{Review.document_status(state, List.first(document.extracted_content))}"}
        >
          <% ec = List.first(document.extracted_content) %>
          <% status = Review.document_status(state, ec) %>
          <% data = row_data(ec) %>
          <% ext =
            document.filename
            |> Path.extname()
            |> String.trim_leading(".")
            |> String.upcase()
            |> String.slice(0, 3) %>
          <.link
            navigate={~p"/documents/#{document}"}
            class="row-preview-link"
            aria-label="Open invoice"
            title="Open"
          >
            <div class="stat">{if ext == "", do: "DOC", else: ext}</div>
            <div class="body">
              <div class="title">
                {(data && data.issuer) || document.filename}
                <.status_pill status={status} run={run} />
              </div>
              <div class="desc">
                <%= case status do %>
                  <% "processing" -> %>
                    {retry_note(run) || "Sent to OCR · extraction in progress"}
                    <%= if ec && ec.status == "failed" do %>
                      · earlier run failed: {get_in(ec.error_details || %{}, ["message"]) ||
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
                  <% "posted" -> %>
                    <span class="amt">
                      {if data && data.amount_to_pay_cents && data.currency,
                        do: fmt_cents(data.amount_to_pay_cents, data.currency),
                        else: "—"}
                    </span>
                    {if data && data.invoice_number, do: " · #{data.invoice_number}", else: ""}
                  <% "rejected" -> %>
                    Rejected{if ec.review_decision.rejection_reason,
                      do: ": #{ec.review_decision.rejection_reason}"}
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
              <.link
                :if={status == "review"}
                class="btn sm primary"
                navigate={~p"/documents/#{document}"}
              >
                Check
              </.link>
              <.link
                patch={preview_path(document, @tab)}
                class="icon-btn"
                aria-label="Preview document"
                title="Preview"
              >
                <.icon name="hero-eye" class="w-4 h-4" />
              </.link>
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
              patch={tab_path(@tab)}
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
    {:noreply, push_patch(socket, to: tab_path(socket.assigns.tab))}
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

  # Loads the documents with their durable processing state and live runs, and
  # resets the stream and hero.
  defp refresh_documents(socket) do
    documents = Documents.list_documents(socket.assigns.current_scope)
    document_ids = Enum.map(documents, & &1.id)
    states = DocumentProcessing.processing_states(document_ids)
    runs = DocumentProcessing.live_runs(document_ids)

    rows =
      Enum.map(documents, &%{id: &1.id, document: &1, state: states[&1.id], run: runs[&1.id]})

    statuses =
      Map.new(
        rows,
        &{&1.id, Review.document_status(&1.state, List.first(&1.document.extracted_content))}
      )

    counts =
      Map.new(@tabs, fn {key, _label} ->
        {key, Enum.count(rows, &in_tab?(key, statuses[&1.id]))}
      end)

    socket
    |> assign(:processing_docs, Enum.filter(documents, &(states[&1.id] == :processing)))
    |> assign(:tab_counts, counts)
    |> assign(:tab_list, @tab_order |> Enum.map(&{&1, @tabs[&1]}))
    |> assign(:tabs, @tabs)
    |> stream(:documents, Enum.filter(rows, &in_tab?(socket.assigns.tab, statuses[&1.id])),
      reset: true
    )
  end

  # Corrections made while checking win over the raw extraction.
  defp row_data(%{review_decision: %ReviewDecision{} = decision}),
    do: ReviewDecision.effective_data(decision)

  defp row_data(%{extracted_data: data}), do: data
  defp row_data(nil), do: nil

  defp in_tab?("all", _status), do: true
  defp in_tab?("needs_action", status), do: Review.needs_action?(status)

  defp in_tab?("posted", status), do: status == "posted"
  defp in_tab?("rejected", status), do: status == "rejected"

  defp tab_path("all"), do: ~p"/documents"
  defp tab_path(tab), do: ~p"/documents?tab=#{tab}"

  defp preview_path(document, "all"), do: ~p"/documents?preview=#{document.id}"
  defp preview_path(document, tab), do: ~p"/documents?tab=#{tab}&preview=#{document.id}"

  defp schedule_prune do
    Process.send_after(self(), :prune_processing_docs, @prune_interval_ms)
  end
end
