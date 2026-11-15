defmodule ZaimuTomoWeb.StatementLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Statements

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:product}>
      <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
        <.link class="btn sm" navigate={~p"/statements"}>← Statements</.link>
        <.link class="btn sm" navigate={~p"/accounts/#{@statement.financial_account}"}>
          {@statement.financial_account.name}
        </.link>
      </div>
      <h1 class="view-title">{title(@statement)}</h1>
      <p class="view-sub">
        {if @statement.period_end, do: "#{@statement.filename} · "}{account_type_label(
          @statement.financial_account.account_type
        )} · {@statement.financial_account.currency}
      </p>

      <div class="grid grid-12" style="margin-top:20px">
        <div class="card span-7" id="statement-summary">
          <div class="card-head">
            <div class="card-title">Statement</div>
            <div id="statement-status"><.status_pill status={Atom.to_string(@status)} /></div>
          </div>
          <div class="detail-row">
            <div class="name">Account</div>
            <div>
              {@statement.financial_account.name}
              <span :if={@statement.account_ref} class="mono dim">· {@statement.account_ref}</span>
            </div>
          </div>
          <div class="detail-row">
            <div class="name">Period</div>
            <div>{period(@statement)}</div>
          </div>
          <div class="detail-row" id="statement-balances">
            <div class="name">Opening → closing</div>
            <div class="num">
              {fmt_cents(@statement.opening_balance_cents, currency(@statement))} → {fmt_cents(
                @statement.closing_balance_cents,
                currency(@statement)
              )}
            </div>
          </div>
          <div :if={@balance} class="detail-row" id="statement-balance">
            <div class="name">Lines add up</div>
            <div>
              <span :if={@balance == :balanced} class="pill verified">Balanced</span>
              <span :if={@balance != :balanced} class="pill review">
                Off by {fmt_cents(off_by(@balance), currency(@statement))}
              </span>
            </div>
          </div>
          <p :if={@status == :failed} class="statement-note" id="statement-failure">
            The last read failed: {Statements.describe_failure(@statement.failure_code)}.{if @statement.extracted_at,
              do: " The lines below are from the earlier read."}
          </p>
          <p :if={@status == :stalled} class="statement-note" id="statement-stalled">
            The read stopped before it finished. Retry to read the statement again.
          </p>
          <p :if={@status == :processing} class="statement-note muted">
            Reading the statement page by page. This page updates when it is done.
          </p>
          <div class="statement-actions">
            <.button
              :if={@retryable?}
              id="statement-retry"
              phx-click="retry"
              phx-disable-with="Starting..."
            >
              Read again
            </.button>
            <.button
              id="statement-delete"
              phx-click="delete"
              data-confirm="Delete this statement and its lines?"
            >
              Delete
            </.button>
          </div>
        </div>

        <div class="card span-5" id="statement-totals">
          <div class="card-head">
            <div class="card-title">Lines</div>
            <div class="card-meta">{length(@statement.lines)} lines</div>
          </div>
          <div class="detail-row">
            <div class="name">Money out</div>
            <div class="num">{fmt_cents(@totals.out, currency(@statement))}</div>
          </div>
          <div class="detail-row">
            <div class="name">Money in</div>
            <div class="num">{fmt_cents(@totals.in, currency(@statement))}</div>
          </div>
        </div>

        <div class="card span-12 ledger-card" id="statement-lines">
          <div :if={@statement.lines == []} class="empty-state">
            <div class="h">No lines</div>
            <div class="muted">
              {if @statement.extracted_at,
                do: "The statement has no transactions in this period.",
                else: "Lines appear once the statement is read."}
            </div>
          </div>
          <div :if={@statement.lines != []} class="statement-line-cols" aria-hidden="true">
            <span>Date</span>
            <span>Description</span>
            <span class="right">Foreign amount</span>
            <span class="right">Amount</span>
          </div>
          <div
            :for={line <- @statement.lines}
            class="statement-line"
            id={"statement-line-#{line.position}"}
          >
            <span class="date">{Calendar.strftime(line.booking_date, "%d.%m.%Y")}</span>
            <span class="description" title={line.description}>{line.description}</span>
            <span class="num right faint">
              {if line.original_currency,
                do: fmt_cents(line.original_amount_cents, line.original_currency)}
            </span>
            <span class={["num right", line.amount_cents > 0 && "credit"]}>
              {fmt_cents(line.amount_cents, line.currency)}
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    # Subscribe first, so a read that finishes while the page loads is not missed.
    if connected?(socket), do: Statements.subscribe(scope)
    statement = Statements.get_statement!(scope, id)

    {:ok,
     socket
     |> assign(:current_path, "/statements")
     |> assign(:refresh_timer, nil)
     |> assign_statement(statement)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    case Statements.retry_extraction(socket.assigns.current_scope, socket.assigns.statement) do
      {:ok, _statement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reading the statement again.")
         |> reload()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "This statement cannot be read again right now.")
         |> reload()}
    end
  end

  def handle_event("delete", _params, socket) do
    case Statements.delete_statement(socket.assigns.current_scope, socket.assigns.statement) do
      {:ok, _statement} ->
        {:noreply,
         socket
         |> put_flash(:info, "Statement deleted.")
         |> push_navigate(to: ~p"/statements")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The statement could not be deleted.")}
    end
  end

  @impl true
  def handle_info({:statement_updated, id}, %{assigns: %{statement: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info({:statement_deleted, id}, %{assigns: %{statement: %{id: id}}} = socket),
    do: {:noreply, deleted(socket)}

  def handle_info({event, _other_id}, socket)
      when event in [:statement_updated, :statement_deleted],
      do: {:noreply, socket}

  def handle_info(:refresh_processing, socket),
    do: {:noreply, socket |> assign(:refresh_timer, nil) |> reload()}

  defp reload(socket) do
    case Statements.get_statement(socket.assigns.current_scope, socket.assigns.statement.id) do
      nil -> deleted(socket)
      statement -> assign_statement(socket, statement)
    end
  end

  defp deleted(socket) do
    socket
    |> put_flash(:info, "This statement was deleted.")
    |> push_navigate(to: ~p"/statements")
  end

  defp assign_statement(socket, statement) do
    status = Statements.status(statement)
    balance = Statements.balance(statement)

    {credits, debits} =
      statement.lines |> Enum.map(& &1.amount_cents) |> Enum.split_with(&(&1 > 0))

    socket
    |> assign(:page_title, title(statement))
    |> assign(:statement, statement)
    |> assign(:status, status)
    |> assign(:balance, balance)
    |> assign(:retryable?, Statements.retryable?(status, balance))
    |> assign(:totals, %{in: Enum.sum(credits), out: Enum.sum(debits)})
    |> schedule_refresh(status == :processing)
  end

  # The job broadcasts before Oban marks it complete, so the reload a broadcast
  # triggers can still see the job running. While it is, re-read until it
  # settles.
  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket, true) do
    if connected?(socket) do
      interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
      assign(socket, :refresh_timer, Process.send_after(self(), :refresh_processing, interval))
    else
      socket
    end
  end

  defp schedule_refresh(socket, _processing?), do: socket

  defp title(%{period_end: nil, filename: filename}), do: filename
  defp title(%{period_end: date}), do: "#{Calendar.strftime(date, "%B %Y")} statement"

  defp period(%{period_start: nil}), do: "—"

  defp period(%{period_start: from, period_end: to}),
    do: "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"

  defp currency(statement), do: statement.currency || statement.financial_account.currency

  defp off_by({:off_by, gap}), do: gap
end
