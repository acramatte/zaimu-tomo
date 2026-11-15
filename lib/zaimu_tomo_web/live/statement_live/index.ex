defmodule ZaimuTomoWeb.StatementLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomo.Statements

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
                <.live_file_input upload={@uploads.statement} style="display:none" />
                <div class="glyph">+</div>
                <div class="h">Drop the statement PDF</div>
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
            <.button type="submit" variant="primary" phx-disable-with="Uploading...">
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
    if connected?(socket), do: Statements.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Statements")
     |> assign(:current_path, "/statements")
     |> assign(:refresh_timer, nil)
     |> assign(:accounts, FinancialAccounts.list_financial_accounts(socket.assigns.current_scope))
     |> allow_upload(:statement,
       accept: ~w(.pdf .jpg .jpeg .png),
       max_file_size: 20_000_000,
       max_entries: 1
     )
     |> assign_statements()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :form, account_form(socket.assigns.accounts, params["account"]))}
  end

  @impl true
  def handle_event("validate", %{"statement" => %{"financial_account_id" => id}}, socket) do
    {:noreply, assign(socket, :form, account_form(socket.assigns.accounts, id))}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :statement, ref)}
  end

  def handle_event("save", %{"statement" => %{"financial_account_id" => account_id}}, socket) do
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

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:statement_updated, :statement_deleted] do
    {:noreply, assign_statements(socket)}
  end

  def handle_info(:refresh_processing, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> assign_statements()}
  end

  defp assign_statements(socket) do
    entries = Statements.list_statements(socket.assigns.current_scope)

    groups =
      entries
      |> Enum.chunk_by(& &1.statement.financial_account_id)
      |> Enum.map(fn [first | _] = group -> {first.statement.financial_account, group} end)

    socket
    |> assign(:groups, groups)
    |> schedule_refresh(Enum.any?(entries, &(&1.status == :processing)))
  end

  # The job broadcasts before Oban marks it complete, so the reload a broadcast
  # triggers can still see the job running. While anything is processing,
  # re-read until it settles.
  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket, true) do
    if connected?(socket) do
      interval = Application.get_env(:zaimu_tomo, :processing_refresh_interval_ms, 3_000)
      assign(socket, :refresh_timer, Process.send_after(self(), :refresh_processing, interval))
    else
      socket
    end
  end

  defp schedule_refresh(socket, _processing?), do: socket

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

  defp upload_error_message(%Ecto.Changeset{errors: [{field, error} | _] = errors}) do
    if Keyword.has_key?(errors, :financial_account_id),
      do: "Choose one of your accounts.",
      else: "#{Phoenix.Naming.humanize(field)} #{translate_error(error)}."
  end

  defp upload_error_label(:too_large), do: "The file is larger than 20 MB."
  defp upload_error_label(:not_accepted), do: "Upload a PDF or an image of the statement."
  defp upload_error_label(:too_many_files), do: "Upload one statement at a time."
  defp upload_error_label(_error), do: "The file could not be uploaded."
end
