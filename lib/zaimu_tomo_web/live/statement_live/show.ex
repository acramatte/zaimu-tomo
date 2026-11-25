defmodule ZaimuTomoWeb.StatementLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{Matcher, Reconciliation}
  alias ZaimuTomoWeb.ProcessingRefresh

  @filters [
    {:all, "all", "All"},
    {:unbacked, "unbacked", "Not backed"},
    {:backed, "backed", "Backed"},
    {:credits, "credits", "Credits"}
  ]
  @filter_by_param Map.new(@filters, fn {filter, param, _label} -> {param, filter} end)
  @confidences Matcher.confidences()

  if Enum.map(@filters, &elem(&1, 0)) != Reconciliation.filters() do
    raise CompileError,
      description: "StatementLive.Show @filters drifted from Reconciliation.filters/0"
  end

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
            <div class="card-meta">{line_count_label(@statement.lines)}</div>
          </div>
          <div class="detail-row">
            <div class="name">Money out</div>
            <div class="num">{fmt_cents(@totals.out, currency(@statement))}</div>
          </div>
          <div class="detail-row">
            <div class="name">Money in</div>
            <div class="num">{fmt_cents(@totals.in, currency(@statement))}</div>
          </div>
          <div :if={@summary.debits > 0} class="statement-coverage" id="statement-coverage">
            <div class="statement-coverage-label">
              <span>{coverage_label(@summary)}</span>
              <span class="muted">by a booked invoice</span>
            </div>
            <div class="budget-bar" aria-hidden="true">
              <div class="fill" style={"width:#{coverage_percent(@summary)}%"}></div>
            </div>
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
          <nav
            :if={@statement.lines != []}
            class="tab-row statement-tabs"
            id="statement-tabs"
            aria-label="Filter lines"
          >
            <.link
              :for={{filter, param, label} <- filters()}
              id={"statement-tab-#{param}"}
              patch={filter_path(@statement, filter)}
              class={["tab", @filter == filter && "active"]}
              aria-current={if @filter == filter, do: "page"}
            >
              {label} <span class="count">{tab_count(@reconciliation, @summary, filter)}</span>
            </.link>
          </nav>
          <div :if={@rows != []} class="statement-line-cols" aria-hidden="true">
            <span>Date</span>
            <span>Description</span>
            <span class="right">Foreign amount</span>
            <span class="right">Amount</span>
            <span>Backing</span>
          </div>
          <div
            :if={@statement.lines != [] and @rows == []}
            class="empty-state"
            id="statement-tab-empty"
          >
            <div class="muted">{empty_tab(@filter)}</div>
          </div>
          <div
            :for={%{line: line, backing: backing} <- @rows}
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
            <.backing line={line} backing={backing} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :line, :any, required: true
  attr :backing, :any, required: true

  defp backing(%{backing: {:matched, entry, confidence}} = assigns)
       when confidence in @confidences do
    assigns = assign(assigns, entry: entry, confidence: confidence)

    ~H"""
    <span class={["backing", @confidence == :named && "named", @confidence == :amount_only && "check"]}>
      <.link navigate={~p"/journal_entries/#{@entry}"} title={entry_label(@entry)}>
        <span :if={@confidence == :amount_only} class="backing-hint">Same amount, check ·</span>
        {entry_label(@entry)}
      </.link>
    </span>
    """
  end

  defp backing(%{line: %{amount_cents: cents}} = assigns) when cents > 0 do
    ~H"""
    <span class="backing faint">Money in</span>
    """
  end

  defp backing(assigns) do
    ~H"""
    <span class="backing none">Not backed</span>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    # Subscribe first, so a read that finishes while the page loads is not missed.
    if connected?(socket) do
      Statements.subscribe(scope)
      Accounting.subscribe_journal_entries(scope)
    end

    reconciliation = Statements.get_reconciliation!(scope, id)

    {:ok,
     socket
     |> assign(:current_path, "/statements")
     |> assign(:filter, :all)
     |> assign_reconciliation(reconciliation)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter = Map.get(@filter_by_param, params["filter"], :all)
    {:noreply, socket |> assign(:filter, filter) |> assign_rows()}
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

  # Another statement's read can take or free an entry this one shares an
  # amount group with, so any statement event re-runs the matching.
  def handle_info({event, _other_id}, socket)
      when event in [:statement_updated, :statement_deleted],
      do: {:noreply, reload(socket)}

  # A posted invoice can back a line here.
  def handle_info({:journal_entry_posted, _id}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(:refresh_processing, socket),
    do: {:noreply, ProcessingRefresh.on_tick(socket, &reload/1)}

  defp reload(socket) do
    case Statements.get_reconciliation(socket.assigns.current_scope, socket.assigns.statement.id) do
      nil -> deleted(socket)
      reconciliation -> socket |> assign_reconciliation(reconciliation) |> assign_rows()
    end
  end

  defp deleted(socket) do
    socket
    |> put_flash(:info, "This statement was deleted.")
    |> push_navigate(to: ~p"/statements")
  end

  defp assign_reconciliation(socket, %Reconciliation{statement: statement} = reconciliation) do
    socket
    |> assign(:page_title, title(statement))
    |> assign(:reconciliation, reconciliation)
    |> assign(:statement, statement)
    |> assign(:status, reconciliation.status)
    |> assign(:balance, reconciliation.balance)
    |> assign(:summary, reconciliation.summary)
    |> assign(:retryable?, Statements.retryable?(reconciliation.status, reconciliation.balance))
    |> assign(:totals, totals(statement))
    |> ProcessingRefresh.schedule(reconciliation.status == :processing)
  end

  defp totals(%{extracted_at: nil}), do: %{in: nil, out: nil}

  defp totals(%{lines: lines}) do
    {credits, debits} = lines |> Enum.map(& &1.amount_cents) |> Enum.split_with(&(&1 > 0))
    %{in: Enum.sum(credits), out: Enum.sum(debits)}
  end

  defp line_count_label([_]), do: "1 line"
  defp line_count_label(lines), do: "#{length(lines)} lines"

  defp assign_rows(socket),
    do:
      assign(
        socket,
        :rows,
        Reconciliation.rows(socket.assigns.reconciliation, socket.assigns.filter)
      )

  defp filters, do: @filters

  defp filter_path(statement, :all), do: ~p"/statements/#{statement}"

  defp filter_path(statement, filter) do
    {_filter, param, _label} = List.keyfind(@filters, filter, 0)
    ~p"/statements/#{statement}?#{[filter: param]}"
  end

  defp tab_count(reconciliation, _summary, :all), do: length(reconciliation.rows)
  defp tab_count(_reconciliation, summary, :backed), do: summary.debits_backed
  defp tab_count(_reconciliation, summary, :unbacked), do: summary.debits - summary.debits_backed
  defp tab_count(_reconciliation, summary, :credits), do: summary.credits

  defp empty_tab(:unbacked), do: "Every payment on this statement is backed by a booked invoice."
  defp empty_tab(:backed), do: "No payment on this statement is backed by a booked invoice yet."
  defp empty_tab(:credits), do: "No money came in on this statement."
  defp empty_tab(:all), do: "No lines."

  defp coverage_label(%{debits_backed: backed, debits: 1}), do: "#{backed} of 1 payment backed"

  defp coverage_label(%{debits_backed: backed, debits: debits}),
    do: "#{backed} of #{debits} payments backed"

  defp coverage_percent(%{debits_backed: backed, debits: debits}),
    do: round(backed * 100 / debits)

  defp entry_label(entry) do
    issuer =
      case entry.issuer do
        text when is_binary(text) ->
          case String.trim(text) do
            "" -> "Invoice"
            trimmed -> trimmed
          end

        _ ->
          "Invoice"
      end

    "#{issuer} · #{Calendar.strftime(entry.date, "%d.%m.%Y")}"
  end

  defp title(%{period_end: nil, filename: filename}), do: filename
  defp title(%{period_end: date}), do: "#{Calendar.strftime(date, "%B %Y")} statement"

  defp period(%{period_start: nil}), do: "—"

  defp period(%{period_start: from, period_end: to}),
    do: "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"

  defp currency(statement), do: statement.currency || statement.financial_account.currency

  defp off_by({:off_by, gap}), do: abs(gap)
end
