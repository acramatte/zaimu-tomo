defmodule ZaimuTomoWeb.FinancialAccountLive.Show do
  use ZaimuTomoWeb, :live_view

  import Ecto.Changeset

  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomoWeb.FinancialAccountHistory

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <.link class="btn sm" navigate={~p"/accounts"}>← Accounts</.link>
    </div>
    <h1 class="view-title">{@account.name}</h1>
    <p class="view-sub">
      {account_type_label(@account.account_type)} account · {@account.currency} · manual balance tracking
    </p>
    <p :if={@account.bank_name || @account.account_number} class="view-sub">
      {@account.bank_name || "Bank not specified"}
      {if @account.account_number, do: " · #{@account.account_number}", else: ""}
    </p>

    <div class="card account-history-card" id="account-balance-history">
      <div class="card-head">
        <div class="card-title">Balance history</div>
        <div class="card-meta">
          {@balance_period_label} · latest snapshot per month · observed points connected across gaps
        </div>
      </div>
      <div :if={!@balance_history_has_values} class="empty-state">
        <div class="h">No balance snapshots in this period</div>
        <div class="muted">Record a balance to add a point to this account's trend.</div>
      </div>
      <.balance_trend_chart
        :if={@balance_history_has_values}
        chart_id={"balance-trend-account-#{@account.id}"}
        currency={@account.currency}
        series={[@balance_history_series]}
      />
    </div>

    <div class="grid grid-12" style="margin-top:20px">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Recorded balances</div>
        </div>
        <div :if={@snapshots == []} class="empty-state">
          <div class="h">No balance snapshots yet</div>
        </div>
        <div :for={snapshot <- @snapshots} class="feed-item" id={"balance-snapshot-#{snapshot.id}"}>
          <div class="stat">{@account.currency}</div>
          <div class="body">
            <div class="title">{snapshot.recorded_on}</div>
          </div>
          <div class="actions">
            <span class="amt">{fmt_cents(snapshot.amount_cents, @account.currency)}</span>
          </div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">Record balance</div>
        </div>
        <.form for={@form} id="record-balance-form" phx-change="validate" phx-submit="save">
          <div style="display:grid;gap:12px">
            <.input
              field={@form[:balance]}
              type="number"
              step="0.01"
              label="Balance"
              placeholder="0.00"
              required
            />
            <.input field={@form[:recorded_on]} type="date" label="Balance date" required />
          </div>
          <div style="margin-top:16px">
            <.button type="submit" variant="primary" phx-disable-with="Saving...">
              Record balance
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    account = FinancialAccounts.get_financial_account!(scope, id)

    {:ok,
     socket
     |> assign(:page_title, account.name)
     |> assign(:current_path, "/accounts")
     |> assign(:account, account)
     |> assign(:form, balance_form())
     |> assign_balance_history()}
  end

  @impl true
  def handle_event("validate", %{"balance" => params}, socket) do
    {:noreply, assign(socket, form: balance_form(params, :validate))}
  end

  def handle_event("save", %{"balance" => params}, socket) do
    form = balance_form(params, :insert)

    with %{valid?: true} <- form.source,
         {:ok, amount_cents} <- amount_to_cents(get_field(form.source, :balance)),
         {:ok, _snapshot} <-
           FinancialAccounts.record_balance(
             socket.assigns.current_scope,
             socket.assigns.account,
             %{amount_cents: amount_cents, recorded_on: get_field(form.source, :recorded_on)}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Balance recorded.")
       |> assign_balance_history()
       |> assign(:form, balance_form())}
    else
      {:error, :invalid_amount} ->
        changeset = add_error(form.source, :balance, "must have at most two decimal places")
        {:noreply, assign(socket, form: to_form(changeset, as: :balance))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :balance))}

      %{valid?: false} ->
        {:noreply, assign(socket, form: to_form(form.source, as: :balance))}
    end
  end

  defp assign_balance_history(socket) do
    scope = socket.assigns.current_scope
    account = socket.assigns.account
    today = Date.utc_today()
    snapshots = FinancialAccounts.list_balance_snapshots(scope, account)

    [series] = FinancialAccountHistory.series([account], snapshots, today)

    socket
    |> assign(:snapshots, snapshots)
    |> assign(:balance_history_series, series)
    |> assign(:balance_history_has_values, Enum.any?(series.points, &(not is_nil(&1.value))))
    |> assign(:balance_period_label, FinancialAccountHistory.period_label(today))
  end

  defp balance_form(params \\ %{}, action \\ nil) do
    params = Map.put_new(params, "recorded_on", Date.to_iso8601(Date.utc_today()))

    {%{}, %{balance: :string, recorded_on: :date}}
    |> cast(params, [:balance, :recorded_on])
    |> validate_required([:balance, :recorded_on])
    |> then(&to_form(&1, as: :balance, action: action))
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
