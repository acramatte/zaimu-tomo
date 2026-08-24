defmodule ZaimuTomoWeb.ActivityLive.Index do
  use ZaimuTomoWeb, :live_view

  @categories [
    %{id: "office",    name: "Office",           color: "oklch(0.55 0.08 240)"},
    %{id: "groceries", name: "Groceries",        color: "oklch(0.55 0.10 145)"},
    %{id: "sport",     name: "Sport",            color: "oklch(0.55 0.13 35)"},
    %{id: "outings",   name: "Outings",          color: "oklch(0.55 0.13 320)"},
    %{id: "transport", name: "Transport",        color: "oklch(0.55 0.10 200)"},
    %{id: "home",      name: "Home & utilities", color: "oklch(0.55 0.07 75)"},
    %{id: "health",    name: "Health",           color: "oklch(0.55 0.10 15)"},
    %{id: "subs",      name: "Subscriptions",    color: "oklch(0.55 0.10 280)"},
    %{id: "travel",    name: "Travel",           color: "oklch(0.55 0.10 250)"},
    %{id: "gifts",     name: "Gifts & giving",   color: "oklch(0.55 0.10 350)"},
    %{id: "misc",      name: "Misc",             color: "oklch(0.55 0.02 60)"},
    %{id: "income",    name: "Income",           color: "oklch(0.50 0.09 155)"},
  ]

  @activity [
    %{id: "j-021", status: "review",     merchant: "Mediamarkt",          filename: "IMG_8821.jpg",        amount: 219.00,  currency: "EUR", date: "2026-05-08", category: nil,         ts: "2026-05-09T09:14:00Z", invoice_no: "MM-2410581", error: nil},
    %{id: "j-020", status: "processing", merchant: "…",                   filename: "scan-2026-05-09.pdf", amount: nil,     currency: nil,   date: nil,          category: nil,         ts: "2026-05-09T09:10:11Z", invoice_no: nil,           error: nil},
    %{id: "j-019", status: "posted",     merchant: "Carrefour Express",   filename: "recu-carrefour.pdf",  amount: 41.62,   currency: "EUR", date: "2026-05-08", category: "groceries", ts: "2026-05-08T18:42:00Z", invoice_no: nil,           error: nil},
    %{id: "j-018", status: "posted",     merchant: "STIB-MIVB",           filename: "mobib-mai.pdf",       amount: 49.00,   currency: "EUR", date: "2026-05-07", category: "transport", ts: "2026-05-07T07:11:00Z", invoice_no: nil,           error: nil},
    %{id: "j-017", status: "posted",     merchant: "Brussels Boulders",   filename: "climb-pass.pdf",      amount: 89.00,   currency: "EUR", date: "2026-05-06", category: "sport",     ts: "2026-05-06T20:02:00Z", invoice_no: nil,           error: nil},
    %{id: "j-016", status: "failed",     merchant: "(unreadable)",        filename: "IMG_3344.heic",       amount: nil,     currency: nil,   date: nil,          category: nil,         ts: "2026-05-06T11:30:00Z", invoice_no: nil,           error: "Image too blurry — confidence 0.18"},
    %{id: "j-015", status: "posted",     merchant: "Café Belga",          filename: "cafe-belga.pdf",      amount: 14.80,   currency: "EUR", date: "2026-05-05", category: "outings",   ts: "2026-05-05T16:20:00Z", invoice_no: nil,           error: nil},
    %{id: "j-014", status: "posted",     merchant: "Spotify",             filename: "inv-spotify.pdf",     amount: 11.99,   currency: "EUR", date: "2026-05-05", category: "subs",      ts: "2026-05-05T03:01:00Z", invoice_no: nil,           error: nil},
    %{id: "j-013", status: "posted",     merchant: "Delhaize",            filename: "recu-delhaize.pdf",   amount: 67.40,   currency: "EUR", date: "2026-05-04", category: "groceries", ts: "2026-05-04T19:11:00Z", invoice_no: nil,           error: nil},
    %{id: "j-012", status: "posted",     merchant: "Salary · Acme NV",    filename: "paystub-04.pdf",      amount: 4280.00, currency: "EUR", date: "2026-04-30", category: "income",    ts: "2026-04-30T09:00:00Z", invoice_no: nil,           error: nil},
    %{id: "j-011", status: "posted",     merchant: "Engie · electricity", filename: "engie-apr.pdf",       amount: 96.40,   currency: "EUR", date: "2026-04-28", category: "home",      ts: "2026-04-28T08:40:00Z", invoice_no: nil,           error: nil},
    %{id: "j-010", status: "posted",     merchant: "Decathlon",           filename: "decathlon.pdf",       amount: 128.99,  currency: "EUR", date: "2026-04-25", category: "sport",     ts: "2026-04-25T14:15:00Z", invoice_no: nil,           error: nil},
  ]

  @tabs [
    {"all", "All"},
    {"review", "Needs review"},
    {"processing", "Processing"},
    {"posted", "Posted"},
    {"failed", "Failed"},
  ]

  @impl true
  def mount(_params, _session, socket) do
    in_flight = Enum.filter(@activity, &(&1.status in ["processing", "review"]))

    counts =
      Map.new(@tabs, fn {key, _label} ->
        n = if key == "all", do: length(@activity), else: Enum.count(@activity, &(&1.status == key))
        {key, n}
      end)

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:activity, @activity)
     |> assign(:in_flight_count, length(in_flight))
     |> assign(:categories, @categories)
     |> assign(:tabs, @tabs)
     |> assign(:filter, "all")
     |> assign(:items, @activity)
     |> assign(:counts, counts)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    items = if status == "all", do: @activity, else: Enum.filter(@activity, &(&1.status == status))
    {:noreply, socket |> assign(:filter, status) |> assign(:items, items)}
  end
end
