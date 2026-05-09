defmodule ZaimuTomoWeb.JournalEntryLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Journal Entries
      </.header>

      <.table
        id="journal-entries"
        rows={@streams.entries}
        row_click={fn {_id, entry} -> JS.navigate(~p"/journal_entries/#{entry}") end}
      >
        <:col :let={{_id, entry}} label="Status">
          <span class={["px-2 py-1 rounded-full text-xs font-medium", status_class(entry.status)]}>
            <%= String.capitalize(entry.status) %>
          </span>
        </:col>
        <:col :let={{_id, entry}} label="Issuer"><%= entry.issuer || "—" %></:col>
        <:col :let={{_id, entry}} label="Invoice #"><%= entry.invoice_number || "—" %></:col>
        <:col :let={{_id, entry}} label="Amount"><%= format_amount(entry) %></:col>
        <:col :let={{_id, entry}} label="Date"><%= format_date(entry.date) %></:col>
        <:col :let={{_id, entry}} label="Category"><%= entry.category || "—" %></:col>
        <:action :let={{_id, entry}}>
          <.link navigate={~p"/journal_entries/#{entry}"}>Show</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Journal Entries")
     |> stream(:entries, list_entries(socket.assigns.current_scope))}
  end

  defp list_entries(%Scope{user: user}), do: Accounting.list_journal_entries(user.id)
  defp list_entries(_), do: []

  defp status_class("posted"), do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300"
  defp status_class(_), do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300"

  defp format_amount(%{amount_cents: cents, currency: currency}) when is_integer(cents) do
    "#{currency} #{cents / 100.0}"
  end
  defp format_amount(_), do: "N/A"

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
