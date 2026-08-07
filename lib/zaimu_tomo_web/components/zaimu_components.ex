defmodule ZaimuTomoWeb.ZaimuComponents do
  use Phoenix.Component
  use ZaimuTomoWeb, :verified_routes

  # ── Number formatting ──────────────────────────────────────────────────────

  def fmt(nil), do: "—"

  def fmt(n) when is_number(n) do
    cents = round(n * 100)
    euros = div(abs(cents), 100)
    frac = rem(abs(cents), 100)
    sign = if n < 0, do: "−", else: ""
    "€#{sign}#{fmt_integer(euros)}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end

  def fmt_cents(nil, _currency), do: "—"

  def fmt_cents(cents, currency) when is_integer(cents) do
    units = div(abs(cents), 100)
    fraction = rem(abs(cents), 100)
    sign = if cents < 0, do: "−", else: ""

    "#{currency} #{sign}#{fmt_integer(units)}.#{String.pad_leading(Integer.to_string(fraction), 2, "0")}"
  end

  def fmt_cents_delta(cents) when is_integer(cents) do
    units = div(abs(cents), 100)
    fraction = rem(abs(cents), 100)
    sign = if cents < 0, do: "−", else: "+"

    "#{sign}#{fmt_integer(units)}.#{String.pad_leading(Integer.to_string(fraction), 2, "0")}"
  end

  def fmt_num(n) when is_number(n) do
    cents = round(n * 100)
    abs_cents = abs(cents)
    euros = div(abs_cents, 100)
    frac = rem(abs_cents, 100)
    sign = if n < 0, do: "−", else: "+"
    "#{sign}#{fmt_integer(euros)}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end

  defp fmt_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  # ── Status pill ────────────────────────────────────────────────────────────

  attr :status, :string, required: true

  def status_pill(assigns) do
    ~H"""
    <%= case @status do %>
      <% "processing" -> %>
        <span class="pill processing"><span class="pulse"></span>Processing</span>
      <% "review" -> %>
        <span class="pill review"><span class="pulse"></span>Needs review</span>
      <% "posted" -> %>
        <span class="pill posted">Posted</span>
      <% "failed" -> %>
        <span class="pill failed">Failed</span>
      <% other -> %>
        <span class="pill">{other}</span>
    <% end %>
    """
  end

  # ── Processing hero ────────────────────────────────────────────────────────

  attr :documents, :list, required: true

  def processing_hero(assigns) do
    ~H"""
    <div :if={@documents != []} class="processing-hero">
      <div>
        <div style="display:flex;align-items:center;gap:10px;font-size:13.5px;font-weight:500">
          <span class="spinner"></span>
          Reading <span class="mono">{List.first(@documents).filename}</span>
          · OCR + extraction
          <span :if={length(@documents) > 1} class="muted">
            + {length(@documents) - 1} more
          </span>
        </div>
        <div class="muted" style="font-size:12px;margin-top:2px">
          Async pipeline · usually <code class="mono">~30s</code>
        </div>
        <div class="progress">
          <div class="progress-fill"></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Bar chart ────────────────────────────────────────────────────────────

  attr :months, :list, required: true

  def bar_chart(assigns) do
    max_value = assigns.months |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end) |> max(1)

    months =
      Enum.map(assigns.months, fn month ->
        Map.put(month, :pct, max(2.0, Float.round(month.value / max_value * 100, 1)))
      end)

    assigns = assign(assigns, months: months)

    ~H"""
    <div class="bar-chart" id="spending-bar-chart">
      <%= for month <- @months do %>
        <.link navigate={month.href} class={["bar-col", month.active && "active"]}>
          <div class="bar-fill" style={"height:#{month.pct}%"}></div>
          <div class="bar-label">{month.label}</div>
        </.link>
      <% end %>
    </div>
    """
  end

  # ── Activity feed item ─────────────────────────────────────────────────────

  attr :item, :map, required: true
  attr :categories, :list, default: []

  def feed_item(assigns) do
    assigns =
      assigns
      |> assign_new(:cat, fn ->
        Enum.find(assigns.categories, &(&1.id == assigns.item.category))
      end)
      |> assign_new(:amt_str, fn ->
        if assigns.item.amount, do: fmt(assigns.item.amount), else: "—"
      end)
      |> assign_new(:ext, fn ->
        if assigns.item.filename,
          do:
            assigns.item.filename
            |> Path.extname()
            |> String.trim_leading(".")
            |> String.upcase()
            |> String.slice(0, 3),
          else: "DOC"
      end)

    ~H"""
    <div class={"feed-item #{@item.status}"}>
      <div class="stat">{@ext}</div>
      <div class="body">
        <div class="title">
          {@item.merchant || if(@item.status == "processing", do: "Scanning…", else: "Untitled")}
          <.status_pill status={@item.status} />
        </div>
        <div class="desc">
          <%= case @item.status do %>
            <% "processing" -> %>
              Sent to OCR · extraction in progress
            <% "review" -> %>
              <span class="amt">{@amt_str}</span> · {@item.invoice_no || "—"} · ready to verify
            <% "posted" -> %>
              <span class="amt">{@amt_str}</span>{if @cat, do: " · #{@cat.name}", else: ""}
            <% "failed" -> %>
              {@item.error || "Processing failed"}
            <% _ -> %>
              {@amt_str}
          <% end %>
          · <span class="muted">{@item.filename}</span>
        </div>
      </div>
      <div class="actions">
        <%= if @item.status == "review" do %>
          <a class="btn sm primary" href={~p"/reviews/#{@item.id}"}>Review</a>
        <% end %>
        <%= if @item.status == "failed" do %>
          <button class="btn sm">Retry</button>
        <% end %>
        <time>{ZaimuTomoWeb.Layouts.rel_time(@item.ts)}</time>
      </div>
    </div>
    """
  end
end
