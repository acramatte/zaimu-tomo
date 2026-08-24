defmodule ZaimuTomoWeb.ReviewLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reviews")
     |> assign(:current_path, "/reviews")
     |> stream(:reviews, list_reviews(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="view-title">Reviews</h1>
    <p class="view-sub">Extracted invoices awaiting your approval</p>

    <div class="card">
      <div class="card-head">
        <div class="card-title">All reviews</div>
      </div>
      <div class="feed" id="reviews-feed" phx-update="stream">
        <div :for={{dom_id, review} <- @streams.reviews} id={dom_id} class={"feed-item #{pill_status(review.review_status)}"}>
          <% data = ReviewDecision.effective_data(review) %>
          <div class="stat">{data.currency || "INV"}</div>
          <div class="body">
            <div class="title">
              {data.issuer || "Unknown issuer"}
              <.status_pill status={pill_status(review.review_status)} />
            </div>
            <div class="desc">
              <span class="amt">{if data.amount_to_pay_cents && data.currency, do: fmt_cents(data.amount_to_pay_cents, data.currency), else: "—"}</span>
              {if data.invoice_number, do: " · #{data.invoice_number}", else: ""}
              · <span class="muted">{data.invoice_date || "—"}</span>
            </div>
          </div>
          <div class="actions">
            <a :if={review.review_status == "pending"} class="btn sm primary" href={~p"/reviews/#{review}"}>Review</a>
            <a :if={review.review_status != "pending"} class="btn sm" href={~p"/reviews/#{review}"}>View</a>
            <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(review.inserted_at))}</time>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp list_reviews(%Scope{user: user}), do: Review.list_review_decisions(user.id)
  defp list_reviews(_), do: []

  defp pill_status("pending"), do: "review"
  defp pill_status(s) when s in ["approved", "amended"], do: "posted"
  defp pill_status("rejected"), do: "failed"
  defp pill_status(other), do: other
end
