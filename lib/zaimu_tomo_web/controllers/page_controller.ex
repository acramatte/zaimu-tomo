defmodule ZaimuTomoWeb.PageController do
  use ZaimuTomoWeb, :controller

  alias ZaimuTomo.{Accounting, FinancialAccounts}

  @category_colors [
    "oklch(0.55 0.08 240)",
    "oklch(0.55 0.10 145)",
    "oklch(0.55 0.13 35)",
    "oklch(0.55 0.13 320)",
    "oklch(0.55 0.10 200)",
    "oklch(0.55 0.07 75)",
    "oklch(0.55 0.10 15)",
    "oklch(0.55 0.10 280)"
  ]

  @categories [
    %{
      id: "office",
      name: "Office",
      glyph: "o",
      color: "oklch(0.55 0.08 240)",
      spent: 184.20,
      budget: 250.0
    },
    %{
      id: "groceries",
      name: "Groceries",
      glyph: "g",
      color: "oklch(0.55 0.10 145)",
      spent: 412.83,
      budget: 500.0
    },
    %{
      id: "sport",
      name: "Sport",
      glyph: "s",
      color: "oklch(0.55 0.13 35)",
      spent: 89.00,
      budget: 80.0
    },
    %{
      id: "outings",
      name: "Outings",
      glyph: "O",
      color: "oklch(0.55 0.13 320)",
      spent: 268.40,
      budget: 200.0
    },
    %{
      id: "transport",
      name: "Transport",
      glyph: "T",
      color: "oklch(0.55 0.10 200)",
      spent: 142.10,
      budget: 180.0
    },
    %{
      id: "home",
      name: "Home & utilities",
      glyph: "h",
      color: "oklch(0.55 0.07 75)",
      spent: 624.00,
      budget: 700.0
    },
    %{
      id: "health",
      name: "Health",
      glyph: "H",
      color: "oklch(0.55 0.10 15)",
      spent: 38.50,
      budget: 120.0
    },
    %{
      id: "subs",
      name: "Subscriptions",
      glyph: "~",
      color: "oklch(0.55 0.10 280)",
      spent: 87.94,
      budget: 100.0
    },
    %{
      id: "travel",
      name: "Travel",
      glyph: "✈",
      color: "oklch(0.55 0.10 250)",
      spent: 0.0,
      budget: 150.0
    },
    %{
      id: "gifts",
      name: "Gifts & giving",
      glyph: "+",
      color: "oklch(0.55 0.10 350)",
      spent: 45.00,
      budget: 60.0
    },
    %{
      id: "misc",
      name: "Misc",
      glyph: "·",
      color: "oklch(0.55 0.02 60)",
      spent: 22.30,
      budget: 80.0
    },
    %{
      id: "income",
      name: "Income",
      glyph: "↓",
      color: "oklch(0.50 0.09 155)",
      spent: 0.0,
      budget: 0.0
    }
  ]

  @activity [
    %{
      id: "j-021",
      status: "review",
      merchant: "Mediamarkt",
      filename: "IMG_8821.jpg",
      amount: 219.00,
      currency: "EUR",
      date: "2026-05-08",
      category: nil,
      ts: "2026-05-09T09:14:00Z",
      invoice_no: "MM-2410581",
      error: nil
    },
    %{
      id: "j-020",
      status: "processing",
      merchant: "…",
      filename: "scan-2026-05-09.pdf",
      amount: nil,
      currency: nil,
      date: nil,
      category: nil,
      ts: "2026-05-09T09:10:11Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-019",
      status: "posted",
      merchant: "Carrefour Express",
      filename: "recu-carrefour.pdf",
      amount: 41.62,
      currency: "EUR",
      date: "2026-05-08",
      category: "groceries",
      ts: "2026-05-08T18:42:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-018",
      status: "posted",
      merchant: "STIB-MIVB",
      filename: "mobib-mai.pdf",
      amount: 49.00,
      currency: "EUR",
      date: "2026-05-07",
      category: "transport",
      ts: "2026-05-07T07:11:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-017",
      status: "posted",
      merchant: "Brussels Boulders",
      filename: "climb-pass.pdf",
      amount: 89.00,
      currency: "EUR",
      date: "2026-05-06",
      category: "sport",
      ts: "2026-05-06T20:02:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-016",
      status: "failed",
      merchant: "(unreadable)",
      filename: "IMG_3344.heic",
      amount: nil,
      currency: nil,
      date: nil,
      category: nil,
      ts: "2026-05-06T11:30:00Z",
      invoice_no: nil,
      error: "Image too blurry — confidence 0.18"
    },
    %{
      id: "j-015",
      status: "posted",
      merchant: "Café Belga",
      filename: "cafe-belga.pdf",
      amount: 14.80,
      currency: "EUR",
      date: "2026-05-05",
      category: "outings",
      ts: "2026-05-05T16:20:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-014",
      status: "posted",
      merchant: "Spotify",
      filename: "inv-spotify.pdf",
      amount: 11.99,
      currency: "EUR",
      date: "2026-05-05",
      category: "subs",
      ts: "2026-05-05T03:01:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-013",
      status: "posted",
      merchant: "Delhaize",
      filename: "recu-delhaize.pdf",
      amount: 67.40,
      currency: "EUR",
      date: "2026-05-04",
      category: "groceries",
      ts: "2026-05-04T19:11:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-012",
      status: "posted",
      merchant: "Salary · Acme NV",
      filename: "paystub-04.pdf",
      amount: 4280.00,
      currency: "EUR",
      date: "2026-04-30",
      category: "income",
      ts: "2026-04-30T09:00:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-011",
      status: "posted",
      merchant: "Engie · electricity",
      filename: "engie-apr.pdf",
      amount: 96.40,
      currency: "EUR",
      date: "2026-04-28",
      category: "home",
      ts: "2026-04-28T08:40:00Z",
      invoice_no: nil,
      error: nil
    },
    %{
      id: "j-010",
      status: "posted",
      merchant: "Decathlon",
      filename: "decathlon.pdf",
      amount: 128.99,
      currency: "EUR",
      date: "2026-04-25",
      category: "sport",
      ts: "2026-04-25T14:15:00Z",
      invoice_no: nil,
      error: nil
    }
  ]

  @upcoming [
    %{d: 12, m: "MAY", name: "Rent · Av. Louise", sub: "Recurring · Home", amt: 1180.00},
    %{d: 15, m: "MAY", name: "Proximus mobile", sub: "Recurring · Subs", amt: 24.99},
    %{d: 21, m: "MAY", name: "Climbing membership", sub: "Annual · Sport", amt: 56.00},
    %{d: 28, m: "MAY", name: "Spotify family", sub: "Recurring · Subs", amt: 17.99},
    %{d: 3, m: "JUN", name: "Tax prepayment Q2", sub: "Scheduled", amt: 482.00}
  ]

  @networth_history [
    41_200,
    41_850,
    41_100,
    42_400,
    43_020,
    43_180,
    43_900,
    43_700,
    44_320,
    44_600,
    45_100,
    44_800,
    45_400,
    45_900,
    46_300,
    46_150,
    46_700,
    47_100,
    46_900,
    47_350,
    47_500,
    47_200,
    47_600,
    47_900,
    47_720,
    47_328
  ]

  @summary %{
    net_worth: 47_328.42,
    cash: 8_978.42,
    investments: 18_450.00,
    savings: 19_900.00,
    month_income: 4_280.00,
    month_expenses: 1_914.27,
    month_budget: 2_240.00,
    month_delta: 325.73,
    projection_eom: 47_640.00
  }

  def home(conn, _params) do
    today = Date.utc_today()
    previous_month = today |> Date.beginning_of_month() |> Date.add(-1)

    spending = Accounting.monthly_spending(conn.assigns.current_scope, today)
    previous_spending = Accounting.monthly_spending(conn.assigns.current_scope, previous_month)
    savings_accounts = FinancialAccounts.list_savings_accounts_with_latest_balance(conn.assigns.current_scope)

    spending_categories =
      spending.categories
      |> spending_categories(previous_spending.categories)
      |> display_spending_categories()

    donut_segments = Enum.map(spending_categories, &%{value: &1.total_cents, color: &1.color})

    in_flight = Enum.filter(@activity, &(&1.status in ["processing", "review"]))

    conn
    |> put_root_layout(html: {ZaimuTomoWeb.Layouts, :zaimutomo})
    |> assign(:current_path, "/")
    |> assign(:page_title, "Dashboard")
    |> assign(:summary, @summary)
    |> assign(:savings_accounts, savings_accounts)
    |> assign(:networth_history, @networth_history)
    |> assign(:categories, @categories)
    |> assign(:spending, spending)
    |> assign(:previous_spending, previous_spending)
    |> assign(:spending_categories, spending_categories)
    |> assign(:spending_month, Calendar.strftime(spending.month_start, "%B"))
    |> assign(:previous_spending_month, Calendar.strftime(previous_spending.month_start, "%B"))
    |> assign(:month_pct, month_pct(spending.total_cents, previous_spending.total_cents))
    |> assign(
      :month_comparison_class,
      month_comparison_class(spending.total_cents, previous_spending.total_cents)
    )
    |> assign(:donut_segments, donut_segments)
    |> assign(:activity, @activity)
    |> assign(:upcoming, @upcoming)
    |> assign(:in_flight_count, length(in_flight))
    |> render(:home)
  end

  defp spending_categories(categories, previous_categories) do
    current_by_category = Map.new(categories, &{&1.category, &1})

    previous_by_category =
      Map.new(previous_categories, fn category ->
        {category.category, category.total_cents}
      end)

    current_by_category
    |> Map.keys()
    |> Kernel.++(Map.keys(previous_by_category))
    |> Enum.uniq()
    |> Enum.map(fn category ->
      current_total_cents =
        current_by_category
        |> Map.get(category, %{total_cents: 0})
        |> Map.fetch!(:total_cents)

      previous_total_cents = Map.get(previous_by_category, category, 0)

      %{
        category: category,
        total_cents: current_total_cents,
        previous_total_cents: previous_total_cents,
        delta_cents: current_total_cents - previous_total_cents
      }
    end)
    |> Enum.sort_by(fn category ->
      {-category.total_cents, -category.previous_total_cents, category.category}
    end)
    |> Enum.with_index()
    |> Enum.map(fn {category, index} ->
      category
      |> Map.put(:color, Enum.at(@category_colors, rem(index, length(@category_colors))))
    end)
  end

  defp display_spending_categories(categories) when length(categories) <= 6, do: categories

  defp display_spending_categories(categories) do
    {visible_categories, remaining_categories} = Enum.split(categories, 5)

    other = %{
      category: "Other",
      color: "oklch(0.55 0.02 60)",
      total_cents: Enum.sum_by(remaining_categories, & &1.total_cents),
      previous_total_cents: Enum.sum_by(remaining_categories, & &1.previous_total_cents),
      delta_cents: Enum.sum_by(remaining_categories, & &1.delta_cents)
    }

    visible_categories ++ [other]
  end

  defp month_pct(0, 0), do: 0.0
  defp month_pct(_current, 0), do: 100.0

  defp month_pct(current, previous) do
    min(100.0, current / previous * 100)
  end

  defp month_comparison_class(current, previous) when previous > 0 and current > previous,
    do: "over"

  defp month_comparison_class(current, previous) when previous > 0 and current > previous * 0.85,
    do: "warn"

  defp month_comparison_class(_current, _previous), do: ""
end
