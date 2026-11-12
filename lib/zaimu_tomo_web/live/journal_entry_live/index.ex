defmodule ZaimuTomoWeb.JournalEntryLive.Index do
  @moduledoc """
  The journal as a condensed ledger: entries still waiting to be booked sit in
  a queue above it, and posted entries are grouped by invoice month for one
  year, loaded a few months at a time. Clicking a row expands its details.
  """
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Review
  alias ZaimuTomoWeb.Spending

  @months_per_load 3
  @filters %{"all" => "All", "not_booked" => "Not booked", "tax_candidates" => "Tax candidates"}

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    {:ok,
     socket
     |> assign(:page_title, "Journal entries")
     |> assign(:current_path, "/journal_entries")
     |> assign(:unbooked, Accounting.list_unbooked_journal_entries(user_id))
     |> assign(:years, Accounting.posted_journal_entry_years(user_id))
     |> assign(:open_id, nil)
     |> assign(:open_document_id, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user_id = socket.assigns.current_scope.user.id
    years = socket.assigns.years
    year = Enum.find(years, List.first(years), &(Integer.to_string(&1) == params["year"]))
    filter = if params["filter"] in Map.keys(@filters), do: params["filter"], else: "all"

    all_months = if year, do: Accounting.posted_journal_months(user_id, year), else: []

    candidate_months =
      if year, do: Accounting.posted_journal_months(user_id, year, "candidate"), else: []

    unbooked_count = length(socket.assigns.unbooked)

    {:noreply,
     socket
     |> assign(year: year, filter: filter, groups: [])
     |> assign(:months, if(filter == "tax_candidates", do: candidate_months, else: all_months))
     |> assign(:filter_counts, %{
       "all" => unbooked_count + Enum.sum_by(all_months, & &1.count),
       "not_booked" => unbooked_count,
       "tax_candidates" => Enum.sum_by(candidate_months, & &1.count)
     })
     |> load_months()}
  end

  @impl true
  def handle_event("select_year", %{"year" => year}, socket) do
    {:noreply, push_patch(socket, to: ledger_path(socket.assigns.filter, year))}
  end

  def handle_event("load_more", _params, socket), do: {:noreply, load_months(socket)}

  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)

    if socket.assigns.open_id == id do
      {:noreply, assign(socket, open_id: nil, open_document_id: nil)}
    else
      {:noreply, assign(socket, open_id: id, open_document_id: unbooked_document_id(socket, id))}
    end
  end

  # Unbooked entries are booked on their invoice page, so their details link there.
  defp unbooked_document_id(socket, id) do
    user_id = socket.assigns.current_scope.user.id

    with %{review_decision_id: decision_id} <- Enum.find(socket.assigns.unbooked, &(&1.id == id)),
         {:ok, decision} <- Review.get_review_decision(decision_id, user_id) do
      decision.extracted_content.document_id
    else
      _ -> nil
    end
  end

  defp load_months(socket) do
    %{months: months, groups: groups} = socket.assigns

    case Enum.slice(months, length(groups), @months_per_load) do
      [] ->
        socket

      next ->
        newest = List.first(next).month
        oldest = List.last(next).month

        entries =
          Accounting.list_posted_journal_entries(
            socket.assigns.current_scope.user.id,
            oldest,
            Date.shift(newest, month: 1),
            if(socket.assigns.filter == "tax_candidates", do: "candidate")
          )
          |> Enum.group_by(&Date.beginning_of_month(&1.date))

        new_groups = Enum.map(next, &%{summary: &1, entries: Map.get(entries, &1.month, [])})
        assign(socket, :groups, groups ++ new_groups)
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        loaded_count: Enum.sum_by(assigns.groups, &length(&1.entries)),
        total_count: Enum.sum_by(assigns.months, & &1.count),
        next_months: Enum.slice(assigns.months, length(assigns.groups), @months_per_load)
      )

    ~H"""
    <h1 class="view-title">Journal entries</h1>
    <p class="view-sub">Posted and pending expense records</p>

    <nav class="invoice-tabs" id="ledger-filters" aria-label="Filter journal entries">
      <.link
        :for={key <- ~w(all not_booked tax_candidates)}
        patch={ledger_path(key, @year)}
        class={["invoice-tab", @filter == key && "active"]}
        aria-current={if @filter == key, do: "page"}
      >
        {filter_label(key)} <span class="count">{@filter_counts[key]}</span>
      </.link>
    </nav>

    <p :if={@filter == "not_booked" && @unbooked == []} class="card ledger-empty muted">
      Nothing left to book.
    </p>

    <section
      :if={@filter != "tax_candidates" && @unbooked != []}
      id="booking-queue"
      class="card ledger-card ledger-queue"
    >
      <div class="ledger-group-head">
        <span>
          <strong>Needs booking</strong>
          <span class="muted">· {length(@unbooked)}</span>
        </span>
        <span class="muted">Book these on their invoice page to move them into the ledger</span>
      </div>
      <.entry_row
        :for={entry <- @unbooked}
        entry={entry}
        open={@open_id == entry.id}
        document_id={@open_document_id}
      />
    </section>

    <section :if={@filter != "not_booked"} id="ledger" class="card ledger-card">
      <div class="ledger-toolbar">
        <div class="card-title">Ledger</div>
        <form :if={@years != []} id="ledger-year" phx-change="select_year">
          <label class="sr-only" for="ledger-year-select">Invoice year</label>
          <select id="ledger-year-select" name="year" class="ledger-select">
            <option :for={year <- @years} value={year} selected={year == @year}>{year}</option>
          </select>
        </form>
      </div>

      <div :if={@groups != []} class="ledger-cols" aria-hidden="true">
        <span>Date</span>
        <span>Issuer</span>
        <span>Category</span>
        <span>N/W</span>
        <span>Tax</span>
        <span class="right">Amount</span>
        <span></span>
      </div>

      <div :for={group <- @groups} id={"month-#{group.summary.month}"} class="ledger-month">
        <div class="ledger-group-head">
          <span>
            <strong>{Calendar.strftime(group.summary.month, "%B %Y")}</strong>
            <span class="muted">· {group.summary.count}</span>
          </span>
          <span class="num">
            {Enum.map_join(group.summary.totals, " · ", fn {currency, cents} ->
              fmt_cents(cents, currency)
            end)}
          </span>
        </div>
        <.entry_row
          :for={entry <- group.entries}
          entry={entry}
          open={@open_id == entry.id}
        />
      </div>

      <p :if={@groups == []} class="ledger-empty muted">
        {if @filter == "tax_candidates",
          do: "No potentially deductible entries in #{@year}.",
          else: "No posted entries yet. Approved invoices appear here once they are booked."}
      </p>

      <div :if={@groups != []} class="ledger-foot">
        <span>
          Showing {month_range(Enum.map(@groups, & &1.summary))} · {@loaded_count} of {@total_count} entries
        </span>
        <button
          :if={@next_months != []}
          id="ledger-load-more"
          type="button"
          class="btn sm"
          phx-click="load_more"
        >
          Load {month_range(@next_months)}
        </button>
        <span :if={@next_months == []}>All of {@year} shown</span>
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :open, :boolean, required: true
  attr :document_id, :integer, default: nil

  defp entry_row(assigns) do
    assigns = assign(assigns, :unbooked?, assigns.entry.status == "uncategorized")

    ~H"""
    <div id={"entry-#{@entry.id}"} class={["ledger-entry", @open && "open"]}>
      <button
        type="button"
        class="ledger-row"
        phx-click="toggle"
        phx-value-id={@entry.id}
        aria-expanded={to_string(@open)}
        aria-controls={"entry-#{@entry.id}-detail"}
      >
        <span class="date" title={format_long_date(@entry.date)}>
          {if @unbooked?, do: short_date(@entry.date), else: day_and_weekday(@entry.date)}
        </span>
        <span class="issuer" title={@entry.issuer}>
          {@entry.issuer || "Unknown issuer"}
          <span :if={@entry.invoice_number} class="inv">{@entry.invoice_number}</span>
        </span>
        <span class="category">
          <span :if={@unbooked?} class="pill review">Needs booking</span>
          <span
            :if={!@unbooked? && @entry.category}
            class="cat-dot"
            style={"background:#{Spending.category_color(@entry.category)}"}
          ></span>
          <span :if={!@unbooked?} class="ellipsis">{@entry.category}</span>
        </span>
        <span class="muted">{need_or_want_label(@entry.need_or_want)}</span>
        <span><.tax_tag :if={!@unbooked?} claim={@entry.tax_deduction_claim} /></span>
        <span class="amount num">{fmt_cents(@entry.amount_cents, @entry.currency)}</span>
        <.icon name="hero-chevron-right" class="ledger-chevron" />
      </button>

      <div :if={@open} id={"entry-#{@entry.id}-detail"} class="ledger-detail">
        <div class="ledger-detail-head">
          <div>
            <div class="detail-issuer">{@entry.issuer || "Unknown issuer"}</div>
            <div class="num">{fmt_cents(@entry.amount_cents, @entry.currency)}</div>
          </div>
          <button
            type="button"
            class="btn sm ghost"
            phx-click="toggle"
            phx-value-id={@entry.id}
            aria-label="Close details"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
        <dl class="ledger-detail-grid">
          <div>
            <dt>Invoice date</dt>
            <dd>{format_long_date(@entry.date)}</dd>
          </div>
          <div>
            <dt>Invoice number</dt>
            <dd class="mono">{@entry.invoice_number || "Not recorded"}</dd>
          </div>
          <div>
            <dt>Booking</dt>
            <dd>
              {if @unbooked?,
                do: "Needs booking",
                else: "#{@entry.category} · #{need_or_want_label(@entry.need_or_want)}"}
            </dd>
          </div>
          <div :if={!@unbooked?}>
            <dt>Tax treatment</dt>
            <dd>
              {if @entry.tax_deduction_claim,
                do: TaxDeductionClaim.status_label(@entry.tax_deduction_claim.status),
                else: "No tax claim recorded"}
            </dd>
          </div>
          <div class="wide">
            <dt>Description</dt>
            <dd>{@entry.description || "—"}</dd>
          </div>
          <div :if={@entry.notes} class="wide">
            <dt>Notes</dt>
            <dd>{@entry.notes}</dd>
          </div>
        </dl>
        <div class="ledger-detail-actions">
          <.link
            :if={@unbooked? && @document_id}
            id={"entry-#{@entry.id}-book"}
            class="btn sm primary"
            navigate={~p"/documents/#{@document_id}?from=journal"}
          >
            Book on the invoice page →
          </.link>
          <.link class="btn sm" navigate={~p"/journal_entries/#{@entry}"}>
            Open entry{if !@unbooked?, do: " to revise tax treatment"}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :claim, :map

  defp tax_tag(%{claim: %{status: "candidate"}} = assigns),
    do: ~H|<span class="pill review">Candidate</span>|

  defp tax_tag(%{claim: %{status: "claimed"}} = assigns),
    do: ~H|<span class="pill posted">Claimed</span>|

  defp tax_tag(%{claim: %{status: "disallowed"}} = assigns),
    do: ~H|<span class="pill failed">Not allowed</span>|

  defp tax_tag(%{claim: %{status: "undecided"}} = assigns),
    do: ~H|<span class="faint">Undecided</span>|

  defp tax_tag(assigns), do: ~H""

  defp filter_label(key), do: Map.fetch!(@filters, key)

  defp ledger_path("all", year), do: ~p"/journal_entries?#{[year: year]}"
  defp ledger_path(filter, year), do: ~p"/journal_entries?#{[filter: filter, year: year]}"

  defp month_range([month]), do: Calendar.strftime(month.month, "%b %Y")

  defp month_range(months) do
    newest = List.first(months).month
    oldest = List.last(months).month
    "#{Calendar.strftime(oldest, "%b")} – #{Calendar.strftime(newest, "%b %Y")}"
  end

  defp day_and_weekday(%Date{} = date), do: Calendar.strftime(date, "%d %a")
  defp day_and_weekday(_), do: "—"

  defp short_date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%y")
  defp short_date(_), do: "—"

  defp format_long_date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  defp format_long_date(_), do: "—"

  defp need_or_want_label("need"), do: "Need"
  defp need_or_want_label("want"), do: "Want"
  defp need_or_want_label(_), do: ""
end
