defmodule ZaimuTomoWeb.JournalEntryLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link navigate={~p"/journal_entries"} class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 flex items-center gap-1">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Journal Entries
        </.link>
      </div>

      <.header>
        <%= entry_title(@entry) %>
      </.header>

      <.list>
        <:item title="Status">
          <span class={["px-2 py-1 rounded-full text-xs font-medium", status_class(@entry.status)]}>
            <%= String.capitalize(@entry.status) %>
          </span>
        </:item>
        <:item title="Invoice Number"><%= @entry.invoice_number || "—" %></:item>
        <:item title="Invoice Date"><%= format_date(@entry.date) %></:item>
        <:item title="Issuer"><%= @entry.issuer || "—" %></:item>
        <:item title="Amount"><%= format_amount(@entry) %></:item>
        <:item title="Description"><%= @entry.description || "—" %></:item>
      </.list>

      <%= if @entry.status == "uncategorized" do %>
        <div class="mt-8">
          <h3 class="text-lg font-medium text-gray-900 dark:text-white mb-4">Assign Category</h3>
          <.form for={%{}} phx-submit="post_entry">
            <div class="grid grid-cols-1 gap-4 max-w-lg">
              <.input name="category" value="" label="Budget Category" placeholder="e.g. Software, Travel, Office" required />
              <.input name="notes" value="" label="Notes" type="textarea" />
            </div>
            <div class="mt-4">
              <.button type="submit" variant="primary" phx-disable-with="Posting...">
                <.icon name="hero-check" /> Post Entry
              </.button>
            </div>
          </.form>
        </div>
      <% else %>
        <div class="mt-8">
          <.list>
            <:item title="Category"><%= @entry.category %></:item>
            <:item title="Notes"><%= @entry.notes || "—" %></:item>
          </.list>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Accounting.get_journal_entry(id, user.id) do
          {:ok, %JournalEntry{} = entry} ->
            {:ok, assign(socket, :entry, entry)}
          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/journal_entries")}
        end
      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("post_entry", %{"category" => category} = params, socket) do
    user_id = socket.assigns.current_scope.user.id
    notes = case Map.get(params, "notes", "") do
      "" -> nil
      n  -> n
    end

    case Accounting.post_entry(socket.assigns.entry, user_id, category, notes) do
      {:ok, updated} ->
        {:noreply, socket |> assign(:entry, updated) |> put_flash(:info, "Entry posted successfully")}
      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to post entry")}
    end
  end

  defp entry_title(%JournalEntry{issuer: issuer, invoice_number: number}) do
    cond do
      issuer && number -> "#{issuer} — #{number}"
      issuer           -> issuer
      number           -> "Invoice #{number}"
      true             -> "Journal Entry"
    end
  end

  defp status_class("posted"), do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300"
  defp status_class(_), do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300"

  defp format_amount(%JournalEntry{amount_cents: cents, currency: currency}) when is_integer(cents) do
    "#{currency} #{cents / 100.0}"
  end
  defp format_amount(_), do: "N/A"

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
