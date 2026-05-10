defmodule ZaimuTomoWeb.DocumentLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Documents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Documents")
     |> assign(:current_path, "/documents")
     |> stream(:documents, Documents.list_documents(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="view-title">Documents</h1>
    <p class="view-sub">All uploaded receipts, invoices, and pay stubs</p>

    <div class="card">
      <div class="card-head">
        <div class="card-title">All files</div>
        <.link navigate={~p"/documents/new"} class="btn sm primary">New expense</.link>
      </div>
      <div class="feed" id="documents-feed" phx-update="stream">
        <div :for={{dom_id, document} <- @streams.documents} id={dom_id} class={"feed-item #{derive_status(List.first(document.extracted_content))}"}>
          <% ec = List.first(document.extracted_content) %>
          <% status = derive_status(ec) %>
          <% data = ec && ec.extracted_data %>
          <% ext = document.filename |> Path.extname() |> String.trim_leading(".") |> String.upcase() |> String.slice(0, 3) %>
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
                  <span class="amt">{if data && data.amount_to_pay_cents, do: fmt(data.amount_to_pay_cents / 100), else: "—"}</span>
                  {if data && data.invoice_number, do: " · #{data.invoice_number}", else: ""}
                  · ready to verify
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
            <a :if={status == "review" && ec && ec.review_decision} class="btn sm primary" href={~p"/reviews/#{ec.review_decision}"}>Review</a>
            <.link :if={status != "posted"} navigate={~p"/documents/#{document}/edit"}>Edit</.link>
            <.link
              phx-click={JS.push("delete", value: %{id: document.id}) |> hide("##{dom_id}")}
              data-confirm="Are you sure?"
            >Delete</.link>
      </div>
      <div>
            <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(document.inserted_at))}</time>
      </div>
          </div>
        </div>
      </div>
    </div>
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
  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(socket, :documents, Documents.list_documents(socket.assigns.current_scope),
       reset: true
     )}
  end

  defp derive_status(nil), do: "processing"
  defp derive_status(%{status: "failed"}), do: "failed"
  defp derive_status(%{review_decision: %{review_status: s}}) when s in ["approved", "amended"], do: "posted"
  defp derive_status(%{review_decision: %{review_status: "rejected"}}), do: "failed"
  defp derive_status(_), do: "review"
end
