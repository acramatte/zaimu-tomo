defmodule ZaimuTomoWeb.JournalEntryLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.Scope

  import ZaimuTomoWeb.TaxTreatmentComponents

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{user: user} ->
        case Accounting.get_journal_entry(id, user.id) do
          {:ok, %JournalEntry{} = entry} ->
            document_id = source_document_id(entry, user.id)
            # Opened from the invoice page: going back returns to that invoice.
            from_invoice? = params["from"] == "invoice" and document_id != nil

            {:ok,
             socket
             |> assign(:page_title, entry_title(entry))
             |> assign(:current_path, "/journal_entries")
             |> assign(:entry, entry)
             |> assign(:document_id, document_id)
             |> assign(:from_invoice?, from_invoice?)
             |> assign(:tax_revision_form, revision_form(entry))}

          {:error, reason} ->
            {:ok, put_flash(socket, :error, reason) |> redirect(to: ~p"/journal_entries")}
        end

      _ ->
        {:ok, put_flash(socket, :error, "Not authenticated") |> redirect(to: ~p"/")}
    end
  end

  defp source_document_id(entry, user_id) do
    case ZaimuTomo.Review.get_review_decision(entry.review_decision_id, user_id) do
      {:ok, decision} -> decision.extracted_content.document_id
      {:error, _reason} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:product}>
      <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
        <.link
          :if={@from_invoice?}
          id="journal-entry-back-to-invoice"
          class="btn sm"
          navigate={~p"/documents/#{@document_id}"}
        >
          ← Invoice
        </.link>
        <a :if={!@from_invoice?} class="btn sm" href={~p"/journal_entries"}>← Journal entries</a>
        <.link
          :if={@document_id && !@from_invoice?}
          id="journal-entry-invoice-link"
          class="btn sm"
          navigate={~p"/documents/#{@document_id}"}
        >
          Open invoice
        </.link>
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
            <div
              :if={@entry.tax_deduction_claim}
              id="journal-entry-deductible-amount"
              class="detail-row"
            >
              <div class="name">Deductible amount</div>
              <div class="num">
                {fmt_cents(@entry.tax_deduction_claim.deductible_amount_cents, @entry.currency)}
              </div>
            </div>
            <div
              :if={@entry.tax_deduction_claim && @entry.tax_deduction_claim.notes}
              id="journal-entry-tax-reason"
              class="detail-row"
            >
              <div class="name">Tax note</div>
              <div>{@entry.tax_deduction_claim.notes}</div>
            </div>
            <div class="detail-row">
              <div class="name">Notes</div>
              <div>{@entry.notes || "—"}</div>
            </div>
            <div style="border-top:1px solid var(--hairline);margin-top:12px;padding-top:12px">
              <.tax_revision_form
                form={@tax_revision_form}
                currency={@entry.currency}
              />
            </div>
          <% else %>
            <p class="muted" style="font-size:13px;margin-bottom:12px">
              This entry still needs a budget category, a need or want choice, and its tax treatment.
            </p>
            <.link
              :if={@document_id}
              id="book-on-invoice-page"
              navigate={~p"/documents/#{@document_id}"}
              class="btn sm primary"
            >
              Book on the invoice page →
            </.link>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("revise_tax_treatment", %{"tax_revision" => params}, socket) do
    with {:ok, attrs} <- revision_attrs(params),
         {:ok, updated} <-
           Accounting.revise_tax_deduction_claim(
             socket.assigns.current_scope,
             socket.assigns.entry,
             attrs
           ) do
      {:noreply,
       socket
       |> assign(:entry, updated)
       |> assign(:tax_revision_form, revision_form(updated))
       |> put_flash(:info, "Tax treatment revised")}
    else
      :error ->
        {:noreply, assign(socket, :tax_revision_form, revision_form(params, :invalid_amount))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :tax_revision_form, revision_form(params, changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revise tax treatment")}
    end
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

  defp need_or_want_label("need"), do: "Need"
  defp need_or_want_label("want"), do: "Want"
  defp need_or_want_label(_), do: "—"

  defp tax_treatment_label(%{status: status}), do: TaxDeductionClaim.status_label(status)
  defp tax_treatment_label(_), do: "—"
end
