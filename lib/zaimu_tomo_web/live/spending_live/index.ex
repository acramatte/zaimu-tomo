defmodule ZaimuTomoWeb.SpendingLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomoWeb.Spending

  @history_months 6

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_month(socket, selected_month(params))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_month(socket, selected_month(params))}
  end

  defp apply_month(socket, month_start) do
    scope = socket.assigns.current_scope

    spending = Accounting.monthly_spending(scope, month_start)
    previous_spending = Accounting.monthly_spending(scope, Spending.shift_month(month_start, -1))

    spending_categories =
      spending.categories
      |> Spending.merge_categories(previous_spending.categories)
      |> Spending.display_categories()

    history = Spending.monthly_history(scope, month_start, @history_months)

    socket
    |> assign(:page_title, "Spending history")
    |> assign(:current_path, "/spending")
    |> assign(:month_start, month_start)
    |> assign(:month_label, Calendar.strftime(month_start, "%B %Y"))
    |> assign(
      :previous_month_label,
      Calendar.strftime(Spending.shift_month(month_start, -1), "%B")
    )
    |> assign(:spending, spending)
    |> assign(:previous_spending, previous_spending)
    |> assign(:spending_categories, spending_categories)
    |> assign(
      :month_pct,
      Spending.month_pct(spending.total_cents, previous_spending.total_cents)
    )
    |> assign(
      :month_comparison_class,
      Spending.month_comparison_class(spending.total_cents, previous_spending.total_cents)
    )
    |> assign(:history, history)
    |> assign(:history_bars, history_bars(history, month_start))
    |> assign(:history_months, @history_months)
    |> assign(:is_current_month, month_start == Date.beginning_of_month(Date.utc_today()))
    |> assign(:prev_month, month_param(Spending.shift_month(month_start, -1)))
    |> assign(:next_month, month_param(Spending.shift_month(month_start, 1)))
  end

  defp selected_month(params) do
    month_start =
      case params["month"] do
        nil -> Date.utc_today()
        month when is_binary(month) -> parse_month_param(month) || Date.utc_today()
        _ -> Date.utc_today()
      end

    current_month_start = Date.beginning_of_month(Date.utc_today())

    if Date.compare(month_start, current_month_start) == :gt do
      current_month_start
    else
      month_start
    end
  end

  defp parse_month_param(month) do
    case Date.from_iso8601("#{month}-01") do
      {:ok, date} -> Date.beginning_of_month(date)
      _ -> nil
    end
  end

  defp month_param(%Date{} = month_start) do
    Calendar.strftime(month_start, "%Y-%m")
  end

  defp history_bars(history, selected_month_start) do
    Enum.map(history, fn month ->
      %{
        label: Calendar.strftime(month.month_start, "%b"),
        value: month.total_cents,
        href: ~p"/spending?month=#{month_param(month.month_start)}",
        active: month.month_start == selected_month_start
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="view-title">Spending <span class="accent">history</span></h1>
    <p class="view-sub">Monthly spending by category, compared with the month before</p>

    <div class="card">
      <div class="month-nav">
        <.link
          patch={~p"/spending?month=#{@prev_month}"}
          class="btn sm ghost"
          aria-label="Previous month"
        >
          ← {Calendar.strftime(Spending.shift_month(@month_start, -1), "%b")}
        </.link>
        <div class="month-nav-label">{@month_label}</div>
        <.link
          :if={!@is_current_month}
          patch={~p"/spending?month=#{@next_month}"}
          class="btn sm ghost"
          aria-label="Next month"
        >
          {Calendar.strftime(Spending.shift_month(@month_start, 1), "%b")} →
        </.link>
        <span :if={@is_current_month} class="btn sm ghost disabled" aria-disabled="true">
          → next
        </span>
      </div>

      <div class="spending-period-summary">
        <div>
          <div class="label">{@month_label} spending</div>
          <div class="spending-period-amount tnum mono">
            {fmt_cents(@spending.total_cents, @spending.currency)}
          </div>
        </div>
        <div class="spending-period-comparison">
          <div class="label">Compared with {@previous_month_label}</div>
          <div class="spending-period-amount tnum mono dim">
            {fmt_cents(@previous_spending.total_cents, @previous_spending.currency)}
          </div>
        </div>
      </div>
      <div class={"budget-bar #{@month_comparison_class}"} style="margin-bottom:14px">
        <div class="fill" style={"width:#{Float.round(@month_pct, 1)}%"}></div>
      </div>

      <div :if={@spending_categories == []} id="spending-empty" class="empty-state">
        <div class="h">No categorized spending in {@month_label}</div>
        <div class="muted">Posted journal entries for this month will appear here.</div>
      </div>
      <div :if={@spending_categories != []} id="spending-categories" style="margin-top:6px">
        <div class="budget-row spending-row spending-row-labels" aria-hidden="true">
          <div class="name">Category</div>
          <div class="num">{Calendar.strftime(@month_start, "%b")}</div>
          <div class="num">{@previous_month_label}</div>
          <div class="num">Change</div>
        </div>
        <%= for cat <- @spending_categories do %>
          <div
            class="budget-row spending-row"
            data-category={cat.category}
            data-total-cents={cat.total_cents}
            data-previous-total-cents={cat.previous_total_cents}
            data-delta-cents={cat.delta_cents}
          >
            <div class="name">
              <span class="cat-dot" style={"background:#{cat.color}"}></span>
              {cat.category}
            </div>
            <div class="num">{fmt_cents(cat.total_cents, @spending.currency)}</div>
            <div class="num dim">
              {fmt_cents(cat.previous_total_cents, @previous_spending.currency)}
            </div>
            <div class={["num", cat.delta_cents > 0 && "over", cat.delta_cents <= 0 && "dim"]}>
              {fmt_cents_delta(cat.delta_cents)}
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <div class="card spending-history-card">
      <div class="card-head">
        <div class="card-title">Last {@history_months} months</div>
        <div class="card-meta">click a bar to open that month</div>
      </div>
      <div :if={Enum.all?(@history, &(&1.total_cents == 0))} id="history-empty" class="empty-state">
        <div class="h">No spending recorded yet</div>
        <div class="muted">Posted journal entries will build this trend over time.</div>
      </div>
      <div :if={!Enum.all?(@history, &(&1.total_cents == 0))} id="history-chart">
        <.bar_chart months={@history_bars} />
      </div>
    </div>
    """
  end
end
