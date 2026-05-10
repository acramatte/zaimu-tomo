defmodule ZaimuTomoWeb.JournalEntryLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Accounting.get_journal_entry(id, user.id) do
          {:ok, %JournalEntry{} = entry} ->
            {:ok,
             socket
             |> assign(:page_title, entry_title(entry))
             |> assign(:current_path, "/journal_entries")
             |> assign(:entry, entry)}

          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/journal_entries")}
        end

      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/journal_entries"}>← Journal entries</a>
    </div>
    <h1 class="view-title" style="margin-top:8px">{@page_title}</h1>

    <div class="grid grid-12">
      <div class="card span-7">
        <div class="card-head">
          <div class="card-title">Invoice details</div>
        </div>
        <div class="detail-row" style="border-bottom:1px solid var(--hairline);padding-bottom:10px;margin-bottom:10px">
          <div class="name">Amount</div>
          <div class="num" style="font-size:20px;font-weight:600">
            {if @entry.amount_cents, do: fmt(@entry.amount_cents / 100), else: "—"}
          </div>
        </div>
        <div class="detail-row"><div class="name">Issuer</div><div>{@entry.issuer || "—"}</div></div>
        <div class="detail-row"><div class="name">Date</div><div>{format_date(@entry.date)}</div></div>
        <div class="detail-row"><div class="name">Invoice #</div><div class="mono dim">{@entry.invoice_number || "—"}</div></div>
        <div class="detail-row"><div class="name">Currency</div><div>{@entry.currency || "—"}</div></div>
        <div class="detail-row"><div class="name">Description</div><div>{@entry.description || "—"}</div></div>
      </div>

      <div class="card span-5">
        <div class="card-head"><div class="card-title">Posting</div></div>
        <%= if @entry.status == "posted" do %>
          <div class="detail-row"><div class="name">Category</div><div>{@entry.category || "—"}</div></div>
          <div class="detail-row"><div class="name">Notes</div><div>{@entry.notes || "—"}</div></div>
        <% else %>
          <p class="muted" style="font-size:13px;margin-bottom:12px">
            Assign a budget category to post this entry to your books.
          </p>
          <.form for={%{}} phx-submit="post_entry">
            <div style="display:grid;gap:10px">
              <.input name="category" value="" label="Budget category" placeholder="e.g. Software, Travel, Office" required />
              <.input name="notes" value="" label="Notes" type="textarea" />
            </div>
            <div style="margin-top:12px">
              <button type="submit" class="btn sm primary" phx-disable-with="Posting…">
                Post entry
              </button>
            </div>
          </.form>
        <% end %>
      </div>
    </div>
    """
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
        {:noreply, socket |> assign(:entry, updated) |> put_flash(:info, "Entry posted")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to post entry")}
    end
  end

  defp entry_title(%JournalEntry{issuer: issuer, invoice_number: number}) do
    cond do
      issuer && number -> "#{issuer} — #{number}"
      issuer           -> issuer
      number           -> "Invoice #{number}"
      true             -> "Journal entry"
    end
  end

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
