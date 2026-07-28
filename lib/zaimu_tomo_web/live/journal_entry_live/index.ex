defmodule ZaimuTomoWeb.JournalEntryLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Journal entries")
     |> assign(:current_path, "/journal_entries")
     |> stream(:entries, list_entries(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="view-title">Journal entries</h1>
    <p class="view-sub">Posted and pending expense records</p>

    <div class="card">
      <div class="card-head">
        <div class="card-title">All entries</div>
      </div>
      <div class="feed" id="entries-feed" phx-update="stream">
        <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="feed-item posted">
          <div class="stat">{entry.currency || "—"}</div>
          <div class="body">
            <div class="title">
              {entry.issuer || "Unknown issuer"}
            </div>
            <div class="desc">
              <span class="amt">
                {if entry.amount_cents && entry.currency,
                  do: fmt_cents(entry.amount_cents, entry.currency),
                  else: "—"}
              </span>
              {if entry.invoice_number, do: " · #{entry.invoice_number}", else: ""} ·
              <span class="muted">{format_date(entry.date)}</span>
              {if entry.category, do: " · #{entry.category}", else: ""}
              {if entry.need_or_want, do: " · #{need_or_want_label(entry.need_or_want)}", else: ""}
            </div>
          </div>
          <div class="actions">
            <a class="btn sm" href={~p"/journal_entries/#{entry}"}>View</a>
            <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(entry.inserted_at))}</time>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp list_entries(%Scope{user: user}), do: Accounting.list_journal_entries(user.id)
  defp list_entries(_), do: []

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"

  defp need_or_want_label("need"), do: "Need"
  defp need_or_want_label("want"), do: "Want"
  defp need_or_want_label(_), do: "—"
end
