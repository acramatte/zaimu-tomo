defmodule ZaimuTomoWeb.JournalEntryLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
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
             |> assign(:entry, entry)
             |> assign_posting_form(entry)}

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
        <div
          class="detail-row"
          style="border-bottom:1px solid var(--hairline);padding-bottom:10px;margin-bottom:10px"
        >
          <div class="name">Amount</div>
          <div class="num" style="font-size:20px;font-weight:600">
            {if @entry.amount_cents && @entry.currency,
              do: fmt_cents(@entry.amount_cents, @entry.currency),
              else: "—"}
          </div>
        </div>
        <div class="detail-row">
          <div class="name">Issuer</div>
          <div>{@entry.issuer || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name">Date</div>
          <div>{format_date(@entry.date)}</div>
        </div>
        <div class="detail-row">
          <div class="name">Invoice #</div>
          <div class="mono dim">{@entry.invoice_number || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name">Currency</div>
          <div>{@entry.currency || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name">Description</div>
          <div>{@entry.description || "—"}</div>
        </div>
      </div>

      <div class="card span-5">
        <div class="card-head">
          <div class="card-title">Posting</div>
        </div>
        <%= if @entry.status == "posted" do %>
          <div class="detail-row">
            <div class="name">Category</div>
            <div>{@entry.category || "—"}</div>
          </div>
          <div class="detail-row">
            <div class="name">Need / Want</div>
            <div>{need_or_want_label(@entry.need_or_want)}</div>
          </div>
          <div id="journal-entry-tax-treatment" class="detail-row">
            <div class="name">Tax treatment</div>
            <div>{tax_treatment_label(@entry.tax_deduction_claim)}</div>
          </div>
          <div :if={tax_treatment_status(@entry) == "candidate"} class="detail-row">
            <div class="name">Tax claim</div>
            <a class="btn sm" href={~p"/tax_claims"}>Resolve claim</a>
          </div>
          <div :if={tax_treatment_status(@entry) == "claimed"} class="detail-row">
            <div class="name">Tax return</div>
            <div id="journal-entry-tax-return-reference">
              {@entry.tax_deduction_claim.tax_return_reference || "—"}
            </div>
          </div>
          <div :if={tax_treatment_status(@entry) == "disallowed"} class="detail-row">
            <div class="name">Tax authority</div>
            <div id="journal-entry-tax-authority">
              {@entry.tax_deduction_claim.authority_name || "—"}
              {if @entry.tax_deduction_claim.authority_reference,
                do: " · #{@entry.tax_deduction_claim.authority_reference}",
                else: ""}
            </div>
          </div>
          <div class="detail-row">
            <div class="name">Notes</div>
            <div>{@entry.notes || "—"}</div>
          </div>
        <% else %>
          <p class="muted" style="font-size:13px;margin-bottom:12px">
            Assign a budget category, classify it as a need or want, and record the tax treatment.
          </p>
          <.form for={@form} id="journal-entry-posting-form" phx-submit="post_entry">
            <div style="display:grid;gap:10px">
              <.input
                field={@form[:category]}
                label="Budget category"
                placeholder="e.g. Software, Travel, Office"
                required
              />
              <.input
                field={@form[:need_or_want]}
                label="Need / Want"
                type="select"
                prompt="Choose one"
                options={[Need: "need", Want: "want"]}
                required
              />
              <.input
                id="posting-tax-treatment-status"
                name="posting[tax_treatment_status]"
                type="select"
                label="Tax treatment"
                value={tax_treatment_status(@entry)}
                options={TaxDeductionClaim.status_options()}
              />
              <.input field={@form[:notes]} label="Notes" type="textarea" />
            </div>
            <div style="margin-top:12px">
              <button
                id="post-entry-button"
                type="submit"
                class="btn sm primary"
                phx-disable-with="Posting…"
              >
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
  def handle_event("post_entry", %{"posting" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id
    category = Map.get(params, "category")
    need_or_want = Map.get(params, "need_or_want")
    tax_claim_attrs = %{"status" => Map.get(params, "tax_treatment_status", "undecided")}

    notes =
      case Map.get(params, "notes", "") do
        "" -> nil
        n -> n
      end

    case Accounting.post_entry(
           socket.assigns.entry,
           user_id,
           category,
           need_or_want,
           notes,
           tax_claim_attrs
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:entry, updated)
         |> assign_posting_form(updated)
         |> put_flash(:info, "Entry posted")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{changeset | action: :insert}, as: :posting))
         |> put_flash(:error, "Failed to post entry")}
    end
  end

  def handle_event("post_entry", _params, socket) do
    {:noreply, put_flash(socket, :error, "Failed to post entry")}
  end

  defp entry_title(%JournalEntry{issuer: issuer, invoice_number: number}) do
    cond do
      issuer && number -> "#{issuer} — #{number}"
      issuer -> issuer
      number -> "Invoice #{number}"
      true -> "Journal entry"
    end
  end

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"

  defp assign_posting_form(socket, %JournalEntry{} = entry) do
    assign(socket, :form, to_form(Accounting.change_journal_entry_posting(entry), as: :posting))
  end

  defp need_or_want_label("need"), do: "Need"
  defp need_or_want_label("want"), do: "Want"
  defp need_or_want_label(_), do: "—"

  defp tax_treatment_label(%{status: status}), do: TaxDeductionClaim.status_label(status)
  defp tax_treatment_label(_), do: "—"

  defp tax_treatment_status(%{tax_deduction_claim: %{status: status}}), do: status
  defp tax_treatment_status(_), do: "undecided"
end
