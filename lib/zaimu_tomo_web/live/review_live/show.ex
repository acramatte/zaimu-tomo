defmodule ZaimuTomoWeb.ReviewLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Review.get_review_decision(id, user.id) do
          {:ok, %ReviewDecision{} = rd} ->
            {:ok,
             socket
             |> assign(:page_title, review_title(rd))
             |> assign(:current_path, "/reviews")
             |> assign(:review_decision, rd)
             |> assign(:effective_data, rd.decision_data || rd.original_data)}

          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/reviews")}
        end

      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/reviews"}>← Reviews</a>
      <.status_pill status={pill_status(@review_decision.review_status)} />
    </div>
    <h1 class="view-title" style="margin-top:8px">{@page_title}</h1>

    <div class="grid grid-12">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Invoice data</div>
          <div :if={@review_decision.review_status == "pending"} class="card-meta">
            <a class="btn sm" href={~p"/reviews/#{@review_decision}/edit"}>Amend</a>
          </div>
        </div>
        <div
          class="detail-row"
          style="border-bottom:1px solid var(--hairline);padding-bottom:10px;margin-bottom:10px"
        >
          <div class="name muted">Amount</div>
          <div class="num" style="font-size:20px;font-weight:600">
            {if @effective_data.amount_to_pay_cents && @effective_data.currency,
              do: fmt_cents(@effective_data.amount_to_pay_cents, @effective_data.currency),
              else: "—"}
          </div>
        </div>
        <div class="detail-row">
          <div class="name muted">Issuer</div>
          <div>{@effective_data.issuer || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Date</div>
          <div>{@effective_data.invoice_date || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Invoice #</div>
          <div class="mono dim">{@effective_data.invoice_number || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Currency</div>
          <div>{@effective_data.currency || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Reason</div>
          <div>{@effective_data.reason_for_payment || "—"}</div>
        </div>
        <div
          :if={@review_decision.review_notes}
          class="detail-row"
          style="margin-top:8px;border-top:1px solid var(--hairline);padding-top:10px"
        >
          <div class="name muted">Notes</div>
          <div>{@review_decision.review_notes}</div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">Decision</div>
        </div>
        <div class="detail-row">
          <div class="name muted">Submitted</div>
          <div>
            {ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(@review_decision.inserted_at))}
          </div>
        </div>
        <%= if @review_decision.review_status == "pending" do %>
          <div style="margin-top:16px;display:flex;gap:8px">
            <button class="btn sm primary" phx-click="approve" phx-disable-with="Approving…">
              Approve &amp; post
            </button>
            <button class="btn sm" phx-click="reject" phx-disable-with="Rejecting…">
              Reject
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("approve", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.approve_invoice(extracted_content_id, user_id) do
      {:ok, decision} ->
        {:noreply, redirect_to_journal_entry(socket, decision, "Invoice approved and posted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    extracted_content_id = socket.assigns.review_decision.extracted_content_id

    case Review.reject_invoice(extracted_content_id, user_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Invoice rejected") |> redirect(to: ~p"/reviews")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp redirect_to_journal_entry(socket, decision, flash_msg) do
    case Accounting.create_from_decision(decision) do
      {:ok, entry} ->
        socket |> put_flash(:info, flash_msg) |> redirect(to: ~p"/journal_entries/#{entry}")

      {:error, _changeset} ->
        socket
        |> put_flash(
          :error,
          "Could not create journal entry because the invoice date is missing or invalid"
        )
        |> redirect(to: ~p"/reviews/#{decision}")
    end
  end

  defp review_title(%ReviewDecision{} = rd) do
    data = rd.decision_data || rd.original_data

    cond do
      data.issuer && data.invoice_number -> "#{data.issuer} — #{data.invoice_number}"
      data.issuer -> data.issuer
      data.invoice_number -> "Invoice #{data.invoice_number}"
      true -> "Invoice review"
    end
  end

  defp pill_status("pending"), do: "review"
  defp pill_status(s) when s in ["approved", "amended"], do: "posted"
  defp pill_status("rejected"), do: "failed"
  defp pill_status(other), do: other
end
