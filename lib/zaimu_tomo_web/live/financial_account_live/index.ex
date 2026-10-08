defmodule ZaimuTomoWeb.FinancialAccountLive.Index do
  use ZaimuTomoWeb, :live_view

  import Ecto.Changeset

  alias ZaimuTomo.Currency
  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomoWeb.FinancialAccountHistory

  @account_types [{"Savings", "savings"}, {"Cash", "cash"}, {"Investment", "investment"}]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-title-row">
      <div>
        <h1 class="view-title">Financial accounts</h1>
        <p class="view-sub">
          Manual balances today; bank connections can update these accounts later.
        </p>
      </div>
    </div>

    <div class="grid grid-12" style="margin-top:20px">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Your accounts</div>
          <div class="card-meta">Balances are shown in their source currency.</div>
        </div>

        <div :if={@accounts == []} class="empty-state" id="accounts-empty">
          <div class="h">No financial accounts yet</div>
          <div class="muted">
            Add savings, cash, or investment accounts. Savings balances appear on the dashboard.
          </div>
        </div>

        <div
          :for={%{account: account, balance_snapshot: snapshot} <- @accounts}
          class="feed-item"
          id={"account-#{account.id}"}
        >
          <div class="stat">{account.currency}</div>
          <div class="body">
            <div class="title">{account.name}</div>
            <div class="desc muted">
              {account_type_label(account.account_type)}
              {if account.bank_name, do: " · #{account.bank_name}", else: ""}
              {if snapshot, do: " · as of #{snapshot.recorded_on}", else: " · no balance recorded"}
            </div>
          </div>
          <div class="actions">
            <span class="amt">
              {if snapshot, do: fmt_cents(snapshot.amount_cents, account.currency), else: "—"}
            </span>
            <.link class="btn sm" navigate={~p"/accounts/#{account}"}>View</.link>
          </div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">Add financial account</div>
        </div>
        <.form for={@form} id="financial-account-form" phx-change="validate" phx-submit="save">
          <div style="display:grid;gap:12px">
            <.input
              field={@form[:name]}
              label="Account name"
              placeholder="Emergency savings"
              required
            />
            <.input
              field={@form[:account_type]}
              type="select"
              label="Type"
              options={@account_types}
              required
            />
            <.input
              field={@form[:currency]}
              label="Currency"
              placeholder="EUR"
              maxlength="3"
              required
            />
            <.input field={@form[:bank_name]} label="Bank name" placeholder="Raiffeisen" />
            <.input
              field={@form[:account_number]}
              label="Account number or IBAN"
              placeholder="CH00 0000 0000 0000 0000 0"
            />
            <.input
              field={@form[:balance]}
              type="number"
              step="0.01"
              label="Current balance"
              placeholder="0.00"
              required
            />
            <.input field={@form[:recorded_on]} type="date" label="Balance date" required />
          </div>
          <div style="margin-top:16px">
            <.button type="submit" variant="primary" phx-disable-with="Saving...">
              Add account
            </.button>
          </div>
        </.form>
      </div>

      <div
        :if={@account_series != []}
        class="card span-12 account-history-card"
        id="account-balance-history"
      >
        <div class="card-head">
          <div class="card-title">Balance history</div>
          <div class="card-meta">
            {@balance_period_label} · observed balances connected across gaps · grouped by currency
          </div>
        </div>

        <div
          class="account-history-controls"
          role="group"
          aria-label="Show or hide accounts in the chart"
        >
          <button
            :for={series <- @account_series}
            id={"account-series-toggle-#{series.account_id}"}
            type="button"
            class="account-history-toggle"
            phx-click="toggle_account"
            phx-value-account_id={series.account_id}
            aria-pressed={to_string(MapSet.member?(@visible_account_ids, series.account_id))}
            aria-label={
              if MapSet.member?(@visible_account_ids, series.account_id),
                do: "Hide #{series.name} from chart",
                else: "Show #{series.name} in chart"
            }
          >
            <span
              class="account-history-swatch"
              style={"background:#{series.color}"}
              aria-hidden="true"
            >
            </span>
            <span>{series.name}</span>
            <span class="account-history-visibility">
              {if MapSet.member?(@visible_account_ids, series.account_id), do: "Shown", else: "Hidden"}
            </span>
          </button>
        </div>

        <div
          :for={group <- @account_series_by_currency}
          class="account-history-currency"
          id={"balance-currency-#{String.downcase(group.currency)}"}
        >
          <h3 class="account-history-currency-title">{group.currency} balances</h3>
          <p class="account-history-total-note">
            <span class="account-history-total-swatch" aria-hidden="true"></span>
            Total wealth · all {group.currency} accounts · latest known balances
          </p>
          <div :if={group.all_accounts_hidden} class="empty-state">
            <div class="h">All {group.currency} accounts are hidden</div>
            <div class="muted">
              Show an account above to restore its line. The total still includes all accounts.
            </div>
          </div>
          <div :if={not group.has_history} class="empty-state">
            <div class="h">No balance snapshots in this period</div>
            <div class="muted">
              The total is shown only once every account in this currency has a recorded balance.
            </div>
          </div>
          <.balance_trend_chart
            :if={group.has_history}
            chart_id={"balance-trend-#{String.downcase(group.currency)}"}
            currency={group.currency}
            series={group.series}
          />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: FinancialAccounts.subscribe_financial_accounts(scope)

    {:ok,
     socket
     |> assign(:page_title, "Financial accounts")
     |> assign(:current_path, "/accounts")
     |> assign(:account_types, @account_types)
     |> assign(:form, account_form())
     |> assign_account_history()}
  end

  @impl true
  def handle_event("toggle_account", %{"account_id" => account_id}, socket) do
    if Enum.any?(socket.assigns.account_series, &(Integer.to_string(&1.account_id) == account_id)) do
      visible_ids =
        if MapSet.member?(socket.assigns.visible_account_ids, String.to_integer(account_id)) do
          MapSet.delete(socket.assigns.visible_account_ids, String.to_integer(account_id))
        else
          MapSet.put(socket.assigns.visible_account_ids, String.to_integer(account_id))
        end

      {:noreply,
       socket
       |> assign(:visible_account_ids, visible_ids)
       |> assign(
         :account_series_by_currency,
         currency_groups(
           socket.assigns.account_series,
           visible_ids,
           socket.assigns.account_totals
         )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"account" => params}, socket) do
    {:noreply, assign(socket, form: account_form(params, :validate))}
  end

  def handle_event("save", %{"account" => params}, socket) do
    form = account_form(params, :insert)

    with %{valid?: true} <- form.source,
         {:ok, amount_cents} <- amount_to_cents(get_field(form.source, :balance)),
         {:ok, _account} <-
           FinancialAccounts.create_financial_account_with_balance(
             socket.assigns.current_scope,
             Map.take(params, ["name", "account_type", "currency", "bank_name", "account_number"]),
             %{amount_cents: amount_cents, recorded_on: get_field(form.source, :recorded_on)}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Financial account added.")
       |> assign_account_history()
       |> assign(:form, account_form())}
    else
      {:error, :invalid_amount} ->
        changeset = add_error(form.source, :balance, "must have at most two decimal places")
        {:noreply, assign(socket, form: to_form(changeset, as: :account, action: :insert))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :account, action: :insert))}

      %{valid?: false} ->
        {:noreply, assign(socket, form: to_form(form.source, as: :account, action: :insert))}
    end
  end

  @impl true
  def handle_info({event, _record}, socket)
      when event in [:created, :updated, :deleted, :balance_recorded] do
    {:noreply, assign_account_history(socket)}
  end

  defp assign_account_history(socket) do
    scope = socket.assigns.current_scope
    today = Date.utc_today()
    start_date = FinancialAccountHistory.first_month(today)
    accounts = FinancialAccounts.list_financial_accounts_with_latest_balance(scope)
    snapshots = FinancialAccounts.list_balance_history(scope, start_date, today)

    series =
      accounts
      |> Enum.map(& &1.account)
      |> FinancialAccountHistory.series(snapshots, today)

    baseline = FinancialAccounts.list_balance_history_baseline(scope, start_date)

    totals =
      accounts
      |> Enum.map(& &1.account)
      |> FinancialAccountHistory.total_series(baseline ++ snapshots, today)
      |> Map.new(&{&1.currency, &1})

    current_ids = series |> Enum.map(& &1.account_id) |> MapSet.new()
    known_ids = Map.get(socket.assigns, :account_series_ids, MapSet.new())
    previous_visible_ids = Map.get(socket.assigns, :visible_account_ids, known_ids)

    visible_ids =
      previous_visible_ids
      |> MapSet.intersection(current_ids)
      |> MapSet.union(MapSet.difference(current_ids, known_ids))

    socket
    |> assign(:accounts, accounts)
    |> assign(:balance_period_label, FinancialAccountHistory.period_label(today))
    |> assign(:account_series, series)
    |> assign(:account_totals, totals)
    |> assign(:account_series_ids, current_ids)
    |> assign(:visible_account_ids, visible_ids)
    |> assign(:account_series_by_currency, currency_groups(series, visible_ids, totals))
  end

  defp currency_groups(series, visible_ids, totals) do
    series
    |> Enum.group_by(& &1.currency)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {currency, currency_series} ->
      visible_series = Enum.filter(currency_series, &MapSet.member?(visible_ids, &1.account_id))

      chart_series = visible_series ++ [Map.fetch!(totals, currency)]

      %{
        currency: currency,
        series: chart_series,
        all_accounts_hidden: visible_series == [],
        has_history:
          Enum.any?(chart_series, fn item -> Enum.any?(item.points, &(not is_nil(&1.value))) end)
      }
    end)
  end

  defp account_form(params \\ %{}, action \\ nil) do
    params = Map.put_new(params, "recorded_on", Date.to_iso8601(Date.utc_today()))

    {%{},
     %{
       name: :string,
       account_type: :string,
       currency: :string,
       bank_name: :string,
       account_number: :string,
       balance: :string,
       recorded_on: :date
     }}
    |> cast(params, [
      :name,
      :account_type,
      :currency,
      :bank_name,
      :account_number,
      :balance,
      :recorded_on
    ])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :account_type, :currency, :balance, :recorded_on])
    |> validate_inclusion(:account_type, Enum.map(@account_types, &elem(&1, 1)))
    |> then(&to_form(&1, as: :account, action: action))
  end

  defp amount_to_cents(amount) when is_binary(amount) do
    with {decimal, ""} <- Decimal.parse(amount),
         cents <- Decimal.mult(decimal, 100),
         true <- Decimal.equal?(cents, Decimal.round(cents, 0)) do
      {:ok, Decimal.to_integer(cents)}
    else
      _ -> {:error, :invalid_amount}
    end
  end

  defp account_type_label(type), do: type |> Atom.to_string() |> String.capitalize()
end
