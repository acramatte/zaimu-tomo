defmodule ZaimuTomoWeb.StatementLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomo.Statements
  alias ZaimuTomoWeb.ProcessingRefresh

  @max_file_size_mb 20
  @max_file_size @max_file_size_mb * 1_000_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:product}>
      <div class="view-title-row">
        <div>
          <h1 class="view-title">Statements</h1>
          <p class="view-sub">
            Monthly bank and card statements, read line by line.
          </p>
        </div>
        <.link :if={@live_action == :index} class="btn primary" patch={~p"/statements/new"}>
          Upload statement
        </.link>
      </div>

      <div :if={@live_action == :new} class="card" id="statement-upload" style="margin-top:20px">
        <div class="card-head">
          <div class="card-title">Upload a statement</div>
          <.link class="btn sm" patch={~p"/statements"}>Cancel</.link>
        </div>

        <div :if={@accounts == []} class="empty-state" id="statement-upload-no-accounts">
          <div class="h">Add an account first</div>
          <div class="muted">
            A statement belongs to one account. <.link navigate={~p"/accounts"}>Add an account</.link>
          </div>
        </div>

        <.form
          :if={@accounts != []}
          for={@form}
          id="statement-form"
          phx-change="validate"
          phx-submit="save"
        >
          <div class="statement-upload-grid">
            <.input
              field={@form[:financial_account_id]}
              type="select"
              label="Account"
              options={Enum.map(@accounts, &{account_option_label(&1), &1.id})}
              required
            />
            <div class="drop-zone" phx-drop-target={@uploads.statement.ref}>
              <label for={@uploads.statement.ref} style="cursor:pointer;display:block">
                <.live_file_input upload={@uploads.statement} class="sr-only" />
                <div class="glyph">+</div>
                <div class="h">Drop the statement PDF or image</div>
                <div class="sub">
                  One file per statement · read page by page · click to
                  <span class="kbd">browse</span>
                </div>
              </label>
            </div>
          </div>

          <div
            :for={entry <- @uploads.statement.entries}
            class="statement-upload-entry"
            id={"statement-upload-entry-#{entry.ref}"}
          >
            <span class="name">{entry.client_name}</span>
            <progress value={entry.progress} max="100" />
            <span class="muted">{entry.progress}%</span>
            <button
              type="button"
              class="btn sm"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              aria-label="Remove file"
            >
              ×
            </button>
            <p
              :for={err <- upload_errors(@uploads.statement, entry)}
              role="alert"
              class="statement-upload-error"
            >
              {upload_error_label(err)}
            </p>
          </div>
          <p
            :for={err <- upload_errors(@uploads.statement)}
            role="alert"
            class="statement-upload-error"
          >
            {upload_error_label(err)}
          </p>

          <div style="margin-top:16px">
            <.button
              type="submit"
              variant="primary"
              disabled={has_upload_errors?(@uploads.statement)}
              phx-disable-with="Uploading..."
            >
              Upload and read
            </.button>
          </div>
        </.form>
      </div>

      <div :if={@groups == []} class="card empty-state" id="statements-empty" style="margin-top:20px">
        <div class="h">No statements yet</div>
        <div class="muted">
          Upload a monthly bank or card statement to see its lines.
        </div>
      </div>

      <div
        :for={{account, entries} <- @groups}
        class="card"
        id={"statements-account-#{account.id}"}
        style="margin-top:20px"
      >
        <div class="card-head">
          <div class="card-title">{account.name}</div>
          <div class="card-meta">
            {account_type_label(account.account_type)} · {account.currency}
          </div>
        </div>
        <div
          :for={%{statement: statement, status: status} <- entries}
          class="feed-item"
          id={"statement-#{statement.id}"}
        >
          <div class="stat">{period_stat(statement)}</div>
          <div class="body">
            <.link class="title" navigate={~p"/statements/#{statement}"}>
              {period_label(statement)}
            </.link>
            <div class="desc muted">{row_detail(statement)}</div>
          </div>
          <div class="actions">
            <span
              :if={@coverage[statement.id]}
              class="statement-coverage-chip"
              id={"statement-#{statement.id}-coverage"}
              title="Payments backed by a booked invoice"
            >
              backed {@coverage[statement.id].debits_backed}/{@coverage[statement.id].debits}
            </span>
            <.status_pill status={Atom.to_string(status)} />
            <.link class="btn sm" navigate={~p"/statements/#{statement}"}>View</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Statements.subscribe(scope)
      FinancialAccounts.subscribe_financial_accounts(scope)
      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "invoice_review:completed")
    end

    {:ok,
     socket
     |> assign(:page_title, "Statements")
     |> assign(:current_path, "/statements")
     |> assign(:accounts, FinancialAccounts.list_financial_accounts(scope))
     |> allow_upload(:statement,
       accept: ~w(.pdf .jpg .jpeg .png),
       max_file_size: @max_file_size,
       max_entries: 1
     )
     |> assign_statements()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> maybe_cancel_pending_uploads()
      |> assign(:form, account_form(socket.assigns.accounts, params["account"]))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"statement" => %{"financial_account_id" => id}}, socket) do
    {:noreply, assign(socket, :form, account_form(socket.assigns.accounts, id))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :statement, ref)}
  end

  def handle_event("save", %{"statement" => %{"financial_account_id" => account_id}}, socket) do
    if has_upload_errors?(socket.assigns.uploads.statement) do
      {:noreply, put_flash(socket, :error, "Fix the file error before uploading.")}
    else
      save_statement(socket, account_id)
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose one of your accounts.")}
  end

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:statement_updated, :statement_deleted] do
    {:noreply, assign_statements(socket)}
  end

  def handle_info({event, _account}, socket) when event in [:created, :updated, :deleted] do
    accounts = FinancialAccounts.list_financial_accounts(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:accounts, accounts)
     |> assign(:form, account_form(accounts, selected_account_id(socket)))}
  end

  def handle_info({:balance_recorded, _snapshot}, socket), do: {:noreply, socket}

  # A posted invoice can back a line of a listed statement.
  def handle_info(%{user_id: user_id}, socket)
      when user_id == socket.assigns.current_scope.user.id,
      do: {:noreply, assign_statements(socket)}

  def handle_info(%{user_id: _other_user}, socket), do: {:noreply, socket}

  def handle_info(:refresh_processing, socket) do
    {:noreply, ProcessingRefresh.on_tick(socket, &assign_statements/1)}
  end

  defp save_statement(socket, account_id) do
    scope = socket.assigns.current_scope

    results =
      consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
        {:ok, Statements.upload_statement(scope, account_id, path, entry.client_name)}
      end)

    case results do
      [{:ok, statement}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Statement uploaded. Reading it now.")
         |> push_navigate(to: ~p"/statements/#{statement}")}

      [{:error, {:already_uploaded, existing}}] ->
        {:noreply,
         socket
         |> put_flash(:info, "This file is already uploaded.")
         |> push_navigate(to: ~p"/statements/#{existing}")}

      [{:error, %Ecto.Changeset{} = changeset}] ->
        {:noreply, put_flash(socket, :error, upload_error_message(changeset))}

      [{:error, _reason}] ->
        {:noreply, put_flash(socket, :error, "Unable to store the statement. Try again.")}

      [] ->
        {:noreply, put_flash(socket, :error, "Choose a statement file first.")}
    end
  end

  defp maybe_cancel_pending_uploads(%{assigns: %{live_action: :index}} = socket) do
    Enum.reduce(
      socket.assigns.uploads.statement.entries,
      socket,
      &cancel_upload(&2, :statement, &1.ref)
    )
  end

  defp maybe_cancel_pending_uploads(socket), do: socket

  defp assign_statements(socket) do
    scope = socket.assigns.current_scope
    entries = Statements.list_statements(scope)

    groups =
      entries
      |> Enum.chunk_by(& &1.statement.financial_account_id)
      |> Enum.map(fn [first | _] = group -> {first.statement.financial_account, group} end)

    ready_ids = for %{statement: statement, status: :ready} <- entries, do: statement.id

    coverage =
      scope
      |> Statements.reconcile(ready_ids)
      |> Map.new(fn {id, reconciliation} -> {id, reconciliation.summary} end)

    socket
    |> assign(:groups, groups)
    |> assign(:coverage, coverage)
    |> ProcessingRefresh.schedule(Enum.any?(entries, &(&1.status == :processing)))
  end

  defp selected_account_id(%{assigns: %{form: form}}) when is_map(form),
    do: form[:financial_account_id].value

  defp selected_account_id(_socket), do: nil

  defp account_form(accounts, requested_id) do
    selected =
      Enum.find(accounts, &(to_string(&1.id) == to_string(requested_id))) || List.first(accounts)

    to_form(%{"financial_account_id" => selected && selected.id}, as: :statement)
  end

  defp account_option_label(account) do
    "#{account.name} · #{account_type_label(account.account_type)} · #{account.currency}"
  end

  defp period_stat(%{period_end: nil}), do: "—"
  defp period_stat(%{period_end: date}), do: Calendar.strftime(date, "%b")

  defp row_detail(%{period_start: nil, inserted_at: uploaded}),
    do: "Uploaded #{Calendar.strftime(uploaded, "%-d %b %Y")}"

  defp row_detail(%{filename: filename}), do: filename

  defp period_label(%{period_start: nil, filename: filename}), do: filename

  defp period_label(%{period_start: from, period_end: to}),
    do: "#{Calendar.strftime(from, "%-d %b %Y")} – #{Calendar.strftime(to, "%-d %b %Y")}"

  defp has_upload_errors?(upload) do
    upload_errors(upload) != [] or Enum.any?(upload.entries, &(upload_errors(upload, &1) != []))
  end

  defp upload_error_message(%Ecto.Changeset{errors: errors}) do
    case {Keyword.fetch(errors, :financial_account_id), Keyword.fetch(errors, :filename)} do
      {{:ok, _error}, _} -> "Choose one of your accounts."
      {:error, {:ok, error}} -> "Filename #{translate_error(error)}."
      _ -> "The statement could not be uploaded."
    end
  end

  defp upload_error_label(:too_large), do: "The file is larger than #{@max_file_size_mb} MB."
  defp upload_error_label(:not_accepted), do: "Upload a PDF or an image of the statement."
  defp upload_error_label(:too_many_files), do: "Upload one statement at a time."
  defp upload_error_label(_error), do: "The file could not be uploaded."
end
