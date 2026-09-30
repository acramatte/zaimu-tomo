defmodule ZaimuTomoWeb.BalanceTrendChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaimuTomoWeb.ZaimuComponents

  test "connects all observed points across gaps without creating missing-month dots" do
    html = render_chart([0, nil, -200, nil, nil, nil, nil, nil, nil, nil, nil, 300])

    assert [_, coordinates] = Regex.run(~r/<polyline[^>]*points="([^"]+)"/, html)
    assert length(String.split(coordinates)) == 3
    assert length(Regex.scan(~r/class="line-point balance-trend-point/, html)) == 3
    assert html =~ "EUR 0.00"
    assert html =~ "EUR −2.00"
  end

  test "renders a single right-edge observation without a line and aligns its tooltip leftwards" do
    html = render_chart([nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 300])

    refute html =~ "<polyline"
    assert html =~ ~s(phx-hook="BalanceTrendTooltip")
    assert html =~ "tooltip-edge-end"
    refute html =~ "tooltip-edge-start"
    assert length(Regex.scan(~r/class="line-point balance-trend-point/, html)) == 1
  end

  test "renders total wealth with a distinct line and an as-of rather than recorded label" do
    html = render_chart([100, 200], :total)

    assert html =~ "balance-trend-total"
    assert html =~ "Total wealth, September 2026: EUR 2.00, as of 2026-09-30"
    refute html =~ "recorded"
  end

  defp render_chart(values, kind \\ :account) do
    points =
      Enum.map(values, fn value ->
        %{
          label: "Sep",
          full_label: "September 2026",
          value: value,
          recorded_on: ~D[2026-09-30]
        }
      end)

    series = %{
      account_id: if(kind == :total, do: "total-EUR", else: 1),
      name: if(kind == :total, do: "Total wealth", else: "Everyday"),
      color: "var(--ink)",
      kind: kind,
      points: points
    }

    render_component(&ZaimuComponents.balance_trend_chart/1,
      series: [series],
      chart_id: "test-chart",
      currency: "EUR"
    )
  end
end
