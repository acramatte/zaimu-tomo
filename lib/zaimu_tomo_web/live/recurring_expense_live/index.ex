defmodule ZaimuTomoWeb.RecurringExpenseLive.Index do
  use ZaimuTomoWeb, :live_view

  import Ecto.Changeset

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Currency
  alias ZaimuTomo.RecurringExpenses
  alias ZaimuTomo.RecurringExpenses.RecurringExpense

  @frequencies [{"Monthly", "monthly"}, {"Quarterly", "quarterly"}, {"Annual", "yearly"}]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-title-row">
      <div>
        <h1 class="view-title">Recurring expenses</h1>
        <p class="view-sub">
          Rent, subscriptions and memberships. The dashboard's “Upcoming” list is built from these.
        </p>
      </div>
    </div>

    <div class="grid grid-12" style="margin-top:20px">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Your recurring expenses</div>
          <div class="card-meta">Amounts are shown in their source currency.</div>
        </div>

        <div :if={@items == []} class="empty-state" id="recurring-empty">
          <div class="h">No recurring expenses yet</div>
          <div class="muted">
            Add your rent, subscriptions or memberships — they will show up under “Upcoming” on the dashboard.
          </div>
        </div>

        <div
          :for={%{expense: expense, reconcile: rec} <- @items}
          class="feed-item"
          id={"recurring-#{expense.id}"}
        >
          <div class="stat">{frequency_glyph(expense.frequency)}</div>
          <div class="body">
            <div class="title">{expense.name}</div>
            <div class="desc muted">
              {frequency_label(expense.frequency)} · {fmt_cents(
                expense.amount_cents,
                expense.currency
              )} · since {expense.start_date}
              {if expense.end_date, do: " · until #{expense.end_date}", else: " · ongoing"}
            </div>
            <div class="reconcile" id={"reconcile-#{expense.id}"}>
              <%= if is_nil(rec.date) do %>
                <div class="reconcile-note muted">
                  Ended {expense.end_date} · no upcoming occurrence
                </div>
              <% else %>
                <%= if rec.covered do %>
                  <div class="reconcile-covered" id={"reconcile-covered-#{expense.id}"}>
                    <span>
                      ✓ Covered by {covering_label(rec.covering_entry)} · {rec.covering_entry.date}
                    </span>
                    <button
                      type="button"
                      class="btn sm ghost"
                      phx-click="unlink"
                      phx-value-entry_id={rec.covering_entry.id}
                    >
                      Unlink
                    </button>
                  </div>
                <% else %>
                  <div class="reconcile-note muted">
                    Next {frequency_label(expense.frequency)} on {rec.date}
                    <%= if rec.candidates == [] do %>
                      · no matching invoice yet — upload it around then and it will be suggested here
                    <% end %>
                  </div>
                  <div
                    :for={entry <- rec.candidates}
                    class="candidate-row"
                    id={"candidate-#{expense.id}-#{entry.id}"}
                  >
                    <span class="muted">
                      {entry.description || entry.issuer || "Invoice"} · {entry.date}
                    </span>
                    <button
                      type="button"
                      class="btn sm"
                      phx-click="link"
                      phx-value-expense_id={expense.id}
                      phx-value-entry_id={entry.id}
                    >
                      Link
                    </button>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
          <div class="actions">
            <span class="amt">{fmt_cents(expense.amount_cents, expense.currency)}</span>
            <button type="button" class="btn sm" phx-click="edit" phx-value-id={expense.id}>
              Edit
            </button>
            <button
              type="button"
              class="btn sm ghost"
              phx-click="delete"
              phx-value-id={expense.id}
              data-confirm={"Delete #{expense.name}? Journal entries stay, their link is cleared."}
            >
              Delete
            </button>
          </div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">
            {if @editing_id, do: "Edit recurring expense", else: "Add recurring expense"}
          </div>
        </div>
        <.form
          for={@form}
          id="recurring-expense-form"
          phx-change="validate"
          phx-submit="save"
        >
          <div style="display:grid;gap:12px">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="Rent · Av. Louise"
              required
            />
            <.input
              field={@form[:amount]}
              type="number"
              step="0.01"
              label="Amount"
              placeholder="0.00"
              required
            />
            <.input
              field={@form[:currency]}
              label="Currency"
              placeholder="EUR"
              maxlength="3"
              required
            />
            <.input
              field={@form[:frequency]}
              type="select"
              label="Frequency"
              options={@frequencies}
              required
            />
            <.input
              field={@form[:start_date]}
              type="date"
              label="Start date"
              required
            />
            <.input
              field={@form[:end_date]}
              type="date"
              label="End date (optional)"
            />
          </div>
          <div style="margin-top:16px;display:flex;gap:8px">
            <.button type="submit" variant="primary" phx-disable-with="Saving...">
              {if @editing_id, do: "Save changes", else: "Add expense"}
            </.button>
            <.button :if={@editing_id} type="button" class="btn sm ghost" phx-click="cancel_edit">
              Cancel
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

    {:ok,
     socket
     |> assign(:page_title, "Recurring expenses")
     |> assign(:current_path, "/recurring")
     |> assign(:frequencies, @frequencies)
     |> assign(:editing_id, nil)
     |> assign(:items, load_items(scope))
     |> assign(:form, expense_form())}
  end

  @impl true
  def handle_event("validate", %{"recurring_expense" => params}, socket) do
    {:noreply, assign(socket, form: expense_form(params, :validate))}
  end

  def handle_event("save", %{"recurring_expense" => params}, socket) do
    scope = socket.assigns.current_scope
    action = if socket.assigns.editing_id, do: :update, else: :insert
    form = expense_form(params, action)

    with %{valid?: true} <- form.source,
         {:ok, amount_cents} <- amount_to_cents(get_field(form.source, :amount)),
         attrs <- %{
           name: get_field(form.source, :name),
           currency: get_field(form.source, :currency),
           frequency: get_field(form.source, :frequency),
           start_date: get_field(form.source, :start_date),
           end_date: get_field(form.source, :end_date),
           amount_cents: amount_cents
         },
         {:ok, _expense} <- save_expense(scope, attrs, socket.assigns.editing_id) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         if(socket.assigns.editing_id,
           do: "Recurring expense updated.",
           else: "Recurring expense added."
         )
       )
       |> assign(:editing_id, nil)
       |> assign(:items, load_items(scope))
       |> assign(:form, expense_form())}
    else
      {:error, :invalid_amount} ->
        changeset = add_error(form.source, :amount, "must have at most two decimal places")
        {:noreply, assign(socket, form: to_form(changeset, as: :recurring_expense))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :recurring_expense))}

      %{valid?: false} ->
        {:noreply,
         assign(socket, form: to_form(form.source, as: :recurring_expense, action: action))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {:ok, expense} = RecurringExpenses.get_recurring_expense(scope, id)

    form =
      expense_form(
        %{
          "name" => expense.name,
          "amount" => format_amount(expense.amount_cents),
          "currency" => expense.currency,
          "frequency" => Atom.to_string(expense.frequency),
          "start_date" => Date.to_iso8601(expense.start_date),
          "end_date" => if(expense.end_date, do: Date.to_iso8601(expense.end_date))
        },
        :edit
      )

    {:noreply, socket |> assign(:editing_id, expense.id) |> assign(:form, form)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:form, expense_form())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {:ok, expense} = RecurringExpenses.get_recurring_expense(scope, id)
    {:ok, _} = RecurringExpenses.delete_recurring_expense(scope, expense)

    {:noreply,
     socket
     |> put_flash(:info, "Recurring expense deleted.")
     |> assign(:editing_id, nil)
     |> assign(:form, expense_form())
     |> assign(:items, load_items(scope))}
  end

  def handle_event("link", %{"expense_id" => expense_id, "entry_id" => entry_id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, expense} <- RecurringExpenses.get_recurring_expense(scope, expense_id),
         {:ok, entry} <- Accounting.get_journal_entry(entry_id, scope.user.id),
         {:ok, _} <- RecurringExpenses.link_journal_entry(scope, expense, entry) do
      {:noreply,
       socket
       |> put_flash(:info, "Invoice linked to #{expense.name}.")
       |> assign(:items, load_items(scope))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unlink", %{"entry_id" => entry_id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, entry} <- Accounting.get_journal_entry(entry_id, scope.user.id),
         {:ok, _} <- RecurringExpenses.unlink_journal_entry(scope, entry) do
      {:noreply,
       socket
       |> put_flash(:info, "Invoice unlinked.")
       |> assign(:items, load_items(scope))}
    else
      _ -> {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_items(scope) do
    today = Date.utc_today()

    scope
    |> RecurringExpenses.list_recurring_expenses()
    |> Enum.map(fn expense ->
      %{expense: expense, reconcile: reconcile(scope, expense, today)}
    end)
  end

  defp reconcile(scope, expense, today) do
    case RecurringExpense.next_occurrence(expense, today) do
      nil ->
        %{date: nil, covered: false, covering_entry: nil, candidates: []}

      date ->
        entries = RecurringExpenses.linked_journal_entries(scope, expense)
        covering_entry = Enum.find(entries, &same_month?(&1.date, date))

        candidates =
          if covering_entry,
            do: [],
            else: RecurringExpenses.candidate_entries(scope, expense, date)

        %{
          date: date,
          covered: not is_nil(covering_entry),
          covering_entry: covering_entry,
          candidates: candidates
        }
    end
  end

  defp same_month?(%Date{} = a, %Date{} = b), do: a.year == b.year and a.month == b.month

  defp save_expense(scope, attrs, nil),
    do: RecurringExpenses.create_recurring_expense(scope, attrs)

  defp save_expense(scope, attrs, id) do
    with {:ok, expense} <- RecurringExpenses.get_recurring_expense(scope, id) do
      RecurringExpenses.update_recurring_expense(scope, expense, attrs)
    end
  end

  defp expense_form(params \\ %{}, action \\ nil) do
    params = Map.put_new(params, "start_date", Date.to_iso8601(Date.utc_today()))

    {%{},
     %{
       name: :string,
       amount: :string,
       currency: :string,
       frequency: :string,
       start_date: :date,
       end_date: :date
     }}
    |> cast(params, [:name, :amount, :currency, :frequency, :start_date, :end_date])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:name, :amount, :currency, :frequency, :start_date])
    |> validate_inclusion(:frequency, Enum.map(@frequencies, &elem(&1, 1)))
    |> validate_end_date_not_before_start_date()
    |> then(&to_form(&1, as: :recurring_expense, action: action))
  end

  defp validate_end_date_not_before_start_date(changeset) do
    with %Date{} = start_date <- get_change(changeset, :start_date),
         %Date{} = end_date <- get_change(changeset, :end_date),
         true <- Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :end_date, "must be on or after the start date")
    else
      _ -> changeset
    end
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

  defp format_amount(cents) do
    units = div(abs(cents), 100)
    fraction = rem(abs(cents), 100)
    "#{units}.#{String.pad_leading(Integer.to_string(fraction), 2, "0")}"
  end

  defp covering_label(entry), do: entry.description || entry.issuer || "Invoice"

  defp frequency_glyph(:monthly), do: "MON"
  defp frequency_glyph(:quarterly), do: "QTR"
  defp frequency_glyph(:yearly), do: "ANN"
end
