defmodule ZaimuTomoWeb.DocumentLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Documents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
    end

    document = Documents.get_document_with_content!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:page_title, document.filename)
     |> assign(:current_path, "/documents")
     |> assign(:document, document)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <% ec = List.first(@document.extracted_content) %>
    <% data = ec && ec.extracted_data %>
    <% status = derive_status(ec) %>

    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/documents"}>← Documents</a>
      <.status_pill status={status} />
    </div>
    <h1 class="view-title" style="margin-top:8px">
      {(data && data.issuer) || @document.filename}
    </h1>
    <p class="view-sub">{@document.filename}</p>

    <div class="grid grid-12">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Extracted data</div>
          <div class="card-meta">
            <.link navigate={~p"/documents/#{@document}/edit?return_to=show"} class="btn sm primary">
              Edit
            </.link>
          </div>
        </div>
        <%= if data do %>
          <div
            class="detail-row"
            style="border-bottom:1px solid var(--hairline);padding-bottom:10px;margin-bottom:10px"
          >
            <div class="name muted">Amount</div>
            <div class="num" style="font-size:20px;font-weight:600">
              {if data.amount_to_pay_cents, do: fmt(data.amount_to_pay_cents / 100), else: "—"}
            </div>
          </div>
          <div class="detail-row">
            <div class="name muted">Issuer</div>
            <div>{data.issuer || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name muted">Date</div>
            <div>{data.invoice_date || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name muted">Invoice #</div>
            <div class="mono dim">{data.invoice_number || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name muted">Currency</div>
            <div>{data.currency || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name muted">Reason</div>
            <div>{data.reason_for_payment || "—"}</div>
          </div>
        <% else %>
          <div class="muted" style="padding:24px 0;text-align:center">
            <%= if status == "processing" do %>
              OCR in progress · check back shortly
            <% else %>
              No extracted data available
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">File</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Filename</div>
          <div class="mono dim">{@document.filename}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Uploaded</div>
          <div>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(@document.inserted_at))}</div>
        </div>
        <%= if status == "review" && ec && ec.review_decision do %>
          <div style="margin-top:16px">
            <a class="btn sm primary" href={~p"/reviews/#{ec.review_decision}"}>Review & post →</a>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(
        {:updated, %ZaimuTomo.Documents.Document{id: id}},
        %{assigns: %{document: %{id: id}}} = socket
      ) do
    document = Documents.get_document_with_content!(socket.assigns.current_scope, id)

    {:noreply, assign(socket, :document, document)}
  end

  def handle_info(
        {:deleted, %ZaimuTomo.Documents.Document{id: id}},
        %{assigns: %{document: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "This document was deleted.")
     |> push_navigate(to: ~p"/documents")}
  end

  def handle_info({type, %ZaimuTomo.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  defp derive_status(nil), do: "processing"
  defp derive_status(%{status: "failed"}), do: "failed"

  defp derive_status(%{review_decision: %{review_status: s}}) when s in ["approved", "amended"],
    do: "posted"

  defp derive_status(%{review_decision: %{review_status: "rejected"}}), do: "failed"
  defp derive_status(_), do: "review"
end
