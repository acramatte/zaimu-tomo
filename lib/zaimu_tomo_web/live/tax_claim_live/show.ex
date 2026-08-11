defmodule ZaimuTomoWeb.TaxClaimLive.Show do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {claim_id, ""} <- Integer.parse(id),
         {:ok, claim} <-
           Accounting.get_tax_deduction_claim(socket.assigns.current_scope, claim_id) do
      {:ok,
       socket
       |> assign(:page_title, "Tax claim")
       |> assign(:current_path, "/tax_claims")
       |> assign_claim(claim)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Tax deduction claim not found")
         |> redirect(to: ~p"/tax_claims")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
      <a class="btn sm" href={~p"/tax_claims?#{[tax_year: @claim.tax_year]}"}>← Tax claims</a>
    </div>
    <div class="view-title-row">
      <div>
        <h1 class="view-title">{@claim.journal_entry.issuer || "Tax claim"}</h1>
        <p class="view-sub">
          Tax year {@claim.tax_year} · {TaxDeductionClaim.status_label(@claim.status)}
        </p>
      </div>
    </div>

    <div class="grid grid-12">
      <section class="card span-7">
        <div class="card-head">
          <div class="card-title">Expense</div>
          <div class="amt">
            {if @claim.deductible_amount_cents && @claim.journal_entry.currency,
              do: fmt_cents(@claim.deductible_amount_cents, @claim.journal_entry.currency),
              else: "—"}
          </div>
        </div>
        <div class="detail-row">
          <div class="name">Invoice</div>
          <div>{@claim.journal_entry.invoice_number || @claim.journal_entry.description || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name">Entry date</div>
          <div>{format_date(@claim.journal_entry.date)}</div>
        </div>
        <div class="detail-row">
          <div class="name">Category</div>
          <div>{@claim.category || "—"}</div>
        </div>
        <div class="detail-row">
          <div class="name">Notes</div>
          <div>{@claim.notes || "—"}</div>
        </div>
        <div style="margin-top:16px">
          <a class="btn sm" href={~p"/journal_entries/#{@claim.journal_entry.id}"}>
            View journal entry
          </a>
        </div>
      </section>

      <section class="card span-5">
        <div class="card-head">
          <div class="card-title">Claim lifecycle</div>
        </div>

        <%= case @claim.status do %>
          <% "candidate" -> %>
            <p class="muted" style="font-size:13px;margin-bottom:16px">
              Decide whether to include this expense in your return. A tax authority decision can only
              be recorded after the claim has been filed.
            </p>
            <.form for={@filing_form} id="tax-claim-file-form" phx-submit="file_claim">
              <div style="display:grid;gap:12px">
                <.input
                  field={@filing_form[:tax_return_reference]}
                  label="Tax return reference"
                  placeholder="e.g. 2026 return — appendix 3"
                  required
                />
              </div>
              <div style="margin-top:16px">
                <.button type="submit" variant="primary" phx-disable-with="Recording…">
                  Include in tax return
                </.button>
              </div>
            </.form>
            <div style="margin-top:20px;padding-top:16px;border-top:1px solid var(--hairline)">
              <div style="font-weight:600">Not deductible after review?</div>
              <p class="muted" style="font-size:13px;margin:6px 0 12px">
                Record your own decision here. This is different from an authority rejecting a filed claim.
              </p>
              <button
                id="tax-claim-mark-not-deductible"
                type="button"
                class="btn sm"
                phx-click="mark_not_deductible"
                phx-disable-with="Recording…"
              >
                Mark not deductible
              </button>
            </div>
          <% "claimed" -> %>
            <div class="detail-row">
              <div class="name">Tax return</div>
              <div id="tax-claim-return-reference">{@claim.tax_return_reference}</div>
            </div>
            <p class="muted" style="font-size:13px;margin:16px 0">
              Keep this claim filed unless a tax authority makes a decision about it.
            </p>
            <.form
              for={@authority_form}
              id="tax-claim-authority-decision-form"
              phx-submit="record_authority_decision"
            >
              <div style="display:grid;gap:12px">
                <.input
                  field={@authority_form[:authority_name]}
                  label="Tax authority"
                  placeholder="e.g. Zurich Tax Office"
                  required
                />
                <.input
                  field={@authority_form[:authority_reference]}
                  label="Authority decision reference"
                  placeholder="e.g. Decision 2026-041"
                  required
                />
              </div>
              <div style="margin-top:16px">
                <.button type="submit" variant="primary" phx-disable-with="Recording…">
                  Record as disallowed
                </.button>
              </div>
            </.form>
          <% "not_deductible" -> %>
            <p id="tax-claim-not-deductible" class="muted">
              You decided not to claim this expense in the tax return.
            </p>
          <% "disallowed" -> %>
            <div class="detail-row">
              <div class="name">Tax return</div>
              <div>{@claim.tax_return_reference || "—"}</div>
            </div>
            <div class="detail-row">
              <div class="name">Tax authority</div>
              <div id="tax-claim-authority-decision">
                {@claim.authority_name} · {@claim.authority_reference}
              </div>
            </div>
          <% _ -> %>
            <p class="muted">This tax claim is not ready for review.</p>
        <% end %>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event("file_claim", %{"filing" => params}, socket) do
    attrs = Map.put(params, "status", "claimed")

    case Accounting.review_tax_deduction_claim(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           attrs
         ) do
      {:ok, claim} ->
        {:noreply,
         socket |> assign_claim(claim) |> put_flash(:info, "Tax claim recorded in return")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :filing_form, to_form(%{changeset | action: :update}, as: :filing))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("mark_not_deductible", _params, socket) do
    case Accounting.review_tax_deduction_claim(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           %{
             "status" => "not_deductible"
           }
         ) do
      {:ok, claim} ->
        {:noreply,
         socket |> assign_claim(claim) |> put_flash(:info, "Tax claim marked not deductible")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("record_authority_decision", %{"authority" => params}, socket) do
    attrs = Map.put(params, "status", "disallowed")

    case Accounting.record_tax_authority_decision(
           socket.assigns.current_scope,
           socket.assigns.claim.id,
           attrs
         ) do
      {:ok, claim} ->
        {:noreply,
         socket |> assign_claim(claim) |> put_flash(:info, "Tax authority decision recorded")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :authority_form, to_form(%{changeset | action: :update}, as: :authority))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp assign_claim(socket, claim) do
    socket
    |> assign(:claim, claim)
    |> assign(
      :filing_form,
      claim
      |> TaxDeductionClaim.changeset_for_candidate_review(%{"status" => "claimed"})
      |> to_form(as: :filing)
    )
    |> assign(
      :authority_form,
      claim
      |> TaxDeductionClaim.changeset_for_authority_decision(%{"status" => "disallowed"})
      |> to_form(as: :authority)
    )
  end

  defp format_error(%Ecto.Changeset{}), do: "Could not update tax claim"
  defp format_error(reason), do: reason

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
