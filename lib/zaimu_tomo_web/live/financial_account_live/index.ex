defmodule ZaimuTomoWeb.FinancialAccountLive.Index do
  use ZaimuTomoWeb, :live_view

  import Ecto.Changeset

  alias ZaimuTomo.Currency
  alias ZaimuTomo.FinancialAccounts

  @account_types [{"Savings", "savings"}, {"Cash", "cash"}, {"Investment", "investment"}]
  @subtypes [{"Retirement", "retirement"}]
  @liquidity_options [{"Liquid", "liquid"}, {"Restricted", "restricted"}, {"Illiquid", "illiquid"}]

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

            <!-- New: subtype and liquidity for investment accounts -->
            <.input
              field={@form[:subtype]}
              type="select"
              label="Subtype"
              options={@subtypes}
            />
            <.input
              field={@form[:liquidity]}
              type="select"
              label="Liquidity"
              options={@liquidity_options}
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
     |> assign(:accounts, FinancialAccounts.list_financial_accounts_with_latest_balance(scope))
     |> assign(:form, account_form())}
  end

  @impl true
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
             Map.take(params, ["name", "account_type", "currency", "bank_name", "account_number", "subtype", "liquidity"]),
             %{amount_cents: amount_cents, recorded_on: get_field(form.source, :recorded_on)}
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Financial account added.")
       |> assign(
         :accounts,
         FinancialAccounts.list_financial_accounts_with_latest_balance(
           socket.assigns.current_scope
         )
       )
       |> assign(:form, account_form())}
    else
      {:error, :invalid_amount} ->
        changeset = add_error(form.source, :balance, "must have at most two decimal places")
        {:noreply, assign(socket, form: to_form(changeset, as: :account))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :account))}

      %{valid?: false} ->
        {:noreply, assign(socket, form: to_form(form.source, as: :account))}
    end
  end

  @impl true
  def handle_info({event, _record}, socket)
      when event in [:created, :updated, :deleted, :balance_recorded] do
    {:noreply,
     assign(
       socket,
       :accounts,
       FinancialAccounts.list_financial_accounts_with_latest_balance(socket.assigns.current_scope)
     )}
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
       subtype: :string,
       liquidity: :string,
       balance: :string,
       recorded_on: :date
     }}
    |> cast(params, [
      :name,
      :account_type,
      :currency,
      :bank_name,
      :account_number,
      :subtype,
      :liquidity,
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
