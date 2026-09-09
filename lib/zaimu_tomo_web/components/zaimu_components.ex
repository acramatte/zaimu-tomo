defmodule ZaimuTomoWeb.ZaimuComponents do
  @moduledoc """
  Shared presentational components for the ZaimuTomo UI.
  """
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

  # ── Recurring expenses ─────────────────────────────────────────────────────

  def frequency_label(:monthly), do: "Monthly"
  def frequency_label(:quarterly), do: "Quarterly"
  def frequency_label(:yearly), do: "Annual"

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

  # ── Line chart ─────────────────────────────────────────────────────────────

  attr :months, :list, required: true
  attr :currency, :string, required: true

  def line_chart(assigns) do
    max_value = assigns.months |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end) |> max(1)
    point_count = length(assigns.months)

    points =
      assigns.months
      |> Enum.with_index()
      |> Enum.map(fn {month, index} ->
        x = (index + 0.5) / point_count * 100
        y = 92 - max(month.value, 0) / max_value * 84
        exact_value = fmt_cents(month.value, assigns.currency)

        Map.merge(month, %{
          x: Float.round(x, 2),
          y: Float.round(y, 2),
          tooltip_below: y < 28,
          exact_value: exact_value,
          accessible_label: "#{month.full_label}: #{exact_value}"
        })
      end)

    axis_ticks =
      for step <- 0..3 do
        value = round(max_value * (3 - step) / 3)

        %{
          y: Float.round(8.0 + step * 28, 2),
          compact_value: compact_cents(value)
        }
      end

    line_points = Enum.map_join(points, " ", &"#{&1.x},#{&1.y}")
    first_point = List.first(points)
    last_point = List.last(points)
    area_points = "#{first_point.x},92 #{line_points} #{last_point.x},92"

    assigns =
      assign(assigns,
        points: points,
        axis_ticks: axis_ticks,
        line_points: line_points,
        area_points: area_points,
        point_count: point_count
      )

    ~H"""
    <div
      class="line-chart"
      id="spending-line-chart"
      role="group"
      aria-label="Monthly spending year to date"
    >
      <div class="line-axis" aria-hidden="true">
        <%= for tick <- @axis_ticks do %>
          <span class="line-axis-label" style={"top:#{tick.y}%"}>
            <span class="line-axis-currency">{@currency}</span> {tick.compact_value}
          </span>
        <% end %>
      </div>
      <div class="line-plot">
        <svg
          class="line-plot-svg"
          viewBox="0 0 100 100"
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          <%= for tick <- @axis_ticks do %>
            <line
              class="line-grid"
              x1="0"
              y1={tick.y}
              x2="100"
              y2={tick.y}
              vector-effect="non-scaling-stroke"
            />
          <% end %>
          <polygon class="line-area" points={@area_points} vector-effect="non-scaling-stroke" />
          <polyline class="line-stroke" points={@line_points} vector-effect="non-scaling-stroke" />
        </svg>
        <%= for point <- @points do %>
          <span
            class={["line-point", point.tooltip_below && "tooltip-below"]}
            style={"left:#{point.x}%;top:#{point.y}%"}
            role="img"
            tabindex="0"
            aria-label={point.accessible_label}
          >
            <span class="line-dot" aria-hidden="true"></span>
            <span class="line-tooltip" role="tooltip">
              {point.full_label} · <strong>{point.exact_value}</strong>
            </span>
          </span>
        <% end %>
      </div>
      <div
        class="line-labels"
        style={"grid-template-columns:repeat(#{@point_count},minmax(0,1fr))"}
        aria-hidden="true"
      >
        <span :for={point <- @points} class="line-label">{point.label}</span>
      </div>
    </div>
    """
  end

  defp compact_cents(cents) do
    absolute_cents = abs(cents)
    sign = if cents < 0, do: "−", else: ""

    cond do
      absolute_cents >= 100_000_000 ->
        "#{sign}#{compact_decimal(absolute_cents / 100_000_000)}m"

      absolute_cents >= 100_000 ->
        "#{sign}#{compact_decimal(absolute_cents / 100_000)}k"

      true ->
        "#{sign}#{fmt_integer(round(absolute_cents / 100))}"
    end
  end

  defp compact_decimal(value) do
    rounded = Float.round(value, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  # ── Dashboard activity feed item ───────────────────────────────────────────

  attr :item, :map, required: true

  def feed_item(assigns) do
    assigns =
      assigns
      |> assign_new(:amount, fn -> fmt_cents(assigns.item.amount_cents, assigns.item.currency) end)
      |> assign_new(:ext, fn ->
        assigns.item.filename
        |> Path.extname()
        |> String.trim_leading(".")
        |> String.upcase()
        |> String.slice(0, 3)
        |> case do
          "" -> "DOC"
          ext -> ext
        end
      end)

    ~H"""
    <div class={"feed-item #{@item.status}"} id={"recent-activity-#{@item.id}"}>
      <div class="stat">{@ext}</div>
      <div class="body">
        <div class="title">
          {@item.merchant || if(@item.status == "processing", do: "Scanning…", else: @item.filename)}
          <.status_pill status={@item.status} />
        </div>
        <div class="desc">
          <%= case @item.status do %>
            <% "processing" -> %>
              Sent to OCR · extraction in progress
            <% "review" -> %>
              <span class="amt">{@amount}</span> · {@item.invoice_no || "—"} · ready to verify
            <% "posted" -> %>
              <span class="amt">{@amount}</span>{if @item.invoice_no,
                do: " · #{@item.invoice_no}",
                else: ""}
            <% "failed" -> %>
              {@item.error || "Processing failed"}
            <% _ -> %>
              {@amount}
          <% end %>
          · <span class="muted">{@item.filename}</span>
        </div>
      </div>
      <div class="actions">
        <a
          :if={@item.status == "review" && @item.review_id}
          class="btn sm primary"
          href={~p"/reviews/#{@item.review_id}"}
        >
          Review
        </a>
        <a
          :if={@item.status == "failed"}
          class="btn sm"
          href={~p"/documents/#{@item.document_id}/edit"}
        >
          View
        </a>
        <time>{ZaimuTomoWeb.Layouts.rel_time(DateTime.to_iso8601(@item.occurred_at))}</time>
      </div>
    </div>
    """
  end

  # ── Static mock activity feed item ─────────────────────────────────────────

  attr :item, :map, required: true
  attr :categories, :list, default: []

  def legacy_feed_item(assigns) do
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
