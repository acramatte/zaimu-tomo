defmodule ZaimuTomoWeb.PageHTML do
  @moduledoc false
  use ZaimuTomoWeb, :html

  embed_templates "page_html/*"

  # ── Number formatting ─────────────────────────────────────────────────────

  def fmt(nil), do: "—"

  def fmt(n) when is_number(n) do
    cents = round(n * 100)
    euros = div(abs(cents), 100)
    frac = rem(abs(cents), 100)
    sign = if n < 0, do: "−", else: ""
    "€#{sign}#{fmt_integer(euros)}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
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

  def fmt_num(n) when is_number(n) do
    cents = round(n * 100)
    abs_cents = abs(cents)
    euros = div(abs_cents, 100)
    frac = rem(abs_cents, 100)
    sign = if n < 0, do: "−", else: "+"
    "#{sign}#{fmt_integer(euros)}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end

  # ── Sparkline SVG ─────────────────────────────────────────────────────────

  attr :values, :list, required: true
  attr :w, :integer, default: 800
  attr :h, :integer, default: 56

  def sparkline(assigns) do
    values = assigns.values
    w = assigns.w * 1.0
    h = assigns.h * 1.0
    min_v = Enum.min(values) * 1.0
    max_v = Enum.max(values) * 1.0
    range = max(max_v - min_v, 1.0)
    n = length(values) - 1
    step_x = w / n

    pts =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        x = Float.round(i * step_x, 1)
        y = Float.round(h - (v * 1.0 - min_v) / range * (h - 6) - 3, 1)
        {x, y}
      end)

    d_path =
      pts
      |> Enum.with_index()
      |> Enum.map(fn {{x, y}, i} -> "#{if i == 0, do: "M", else: "L"}#{x} #{y}" end)
      |> Enum.join(" ")

    {last_x, last_y} = List.last(pts)
    d_area = "#{d_path} L #{trunc(w)} #{trunc(h)} L 0 #{trunc(h)} Z"

    assigns =
      assign(assigns,
        d_path: d_path,
        d_area: d_area,
        last_x: last_x,
        last_y: last_y
      )

    ~H"""
    <svg class="spark" viewBox={"0 0 #{@w} #{@h}"} preserveAspectRatio="none">
      <defs>
        <linearGradient id="sparkfill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stop-color="oklch(0.45 0.08 155)" stop-opacity="0.16" />
          <stop offset="100%" stop-color="oklch(0.45 0.08 155)" stop-opacity="0" />
        </linearGradient>
      </defs>
      <path d={@d_area} fill="url(#sparkfill)" />
      <path d={@d_path} fill="none" stroke="oklch(0.45 0.08 155)" stroke-width="1.5" />
      <circle cx={@last_x} cy={@last_y} r="3" fill="oklch(0.45 0.08 155)" />
      <circle cx={@last_x} cy={@last_y} r="6" fill="oklch(0.45 0.08 155)" opacity="0.18" />
    </svg>
    """
  end

  # ── Donut chart SVG ───────────────────────────────────────────────────────

  attr :segments, :list, required: true
  attr :size, :integer, default: 160

  def donut_chart(assigns) do
    size = assigns.size * 1.0
    r = size / 2 - 12
    cx = size / 2
    cy = size / 2
    circumference = 2 * :math.pi() * r
    total = assigns.segments |> Enum.map(& &1.value) |> Enum.sum() |> max(1)

    {arcs, _offset} =
      Enum.reduce(assigns.segments, {[], 0.0}, fn seg, {acc, off} ->
        len = Float.round(seg.value / total * circumference, 2)
        arc = %{
          color: seg.color,
          len: len,
          gap: Float.round(circumference - len, 2),
          offset: Float.round(-off, 2)
        }
        {acc ++ [arc], off + len}
      end)

    assigns = assign(assigns, arcs: arcs, r: r, cx: cx, cy: cy, size: size)

    ~H"""
    <svg viewBox={"0 0 #{trunc(@size)} #{trunc(@size)}"}>
      <circle
        :for={arc <- @arcs}
        cx={@cx}
        cy={@cy}
        r={@r}
        fill="none"
        stroke={arc.color}
        stroke-width="14"
        stroke-dasharray={"#{arc.len} #{arc.gap}"}
        stroke-dashoffset={arc.offset}
      />
    </svg>
    """
  end

  # ── Status pill ───────────────────────────────────────────────────────────

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
end
