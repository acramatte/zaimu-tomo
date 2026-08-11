defmodule ZaimuTomoWeb.TaxClaimLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim

  @impl true
  def mount(_params, _session, socket) do
    claims = Accounting.list_candidate_tax_deduction_claims(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Tax claims")
     |> assign(:current_path, "/tax_claims")
     |> assign(:claims, claims)
     |> assign(:resolution_forms, resolution_forms(claims))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-title-row">
      <div>
        <h1 class="view-title">Tax claims</h1>
        <p class="view-sub">
          Resolve potentially deductible expenses once they reach your return or tax authority.
        </p>
      </div>
    </div>

    <div :if={@claims == []} id="tax-claims-empty" class="card empty-state">
      <div class="h">No candidate claims</div>
      <div class="muted">
        Mark a posted journal entry as potentially deductible to resolve it here later.
      </div>
    </div>

    <div :for={claim <- @claims} id={"tax-claim-#{claim.id}"} class="card" style="margin-top:16px">
      <% entry = claim.journal_entry %>
      <div class="card-head">
        <div>
          <div class="card-title">{entry.issuer || "Unknown issuer"}</div>
          <div class="card-meta">
            Tax year {claim.tax_year} · {TaxDeductionClaim.status_label(claim.status)}
          </div>
        </div>
        <div class="amt">
          {if claim.deductible_amount_cents && entry.currency,
            do: fmt_cents(claim.deductible_amount_cents, entry.currency),
            else: "—"}
        </div>
      </div>

      <div class="detail-row">
        <div class="name">Invoice</div>
        <div>{entry.invoice_number || entry.description || "—"}</div>
      </div>
      <div class="detail-row">
        <div class="name">Entry date</div>
        <div>{format_date(entry.date)}</div>
      </div>

      <.form
        for={@resolution_forms[claim.id]}
        id={"tax-claim-resolution-form-#{claim.id}"}
        phx-submit="resolve"
        style="margin-top:16px"
      >
        <input type="hidden" name="claim_id" value={claim.id} />
        <div style="display:grid;gap:12px">
          <.input
            field={@resolution_forms[claim.id][:status]}
            type="select"
            label="Resolution"
            options={TaxDeductionClaim.resolution_options()}
          />
          <.input
            field={@resolution_forms[claim.id][:tax_return_reference]}
            label="Tax return reference"
            placeholder="e.g. 2026 return — appendix 3"
          />
          <p class="muted" style="font-size:12px;margin-top:-6px">
            Required when recording the claim in a return.
          </p>
          <.input
            field={@resolution_forms[claim.id][:authority_name]}
            label="Tax authority"
            placeholder="e.g. Zurich Tax Office"
          />
          <.input
            field={@resolution_forms[claim.id][:authority_reference]}
            label="Authority decision reference"
            placeholder="e.g. Decision 2026-041"
          />
          <p class="muted" style="font-size:12px;margin-top:-6px">
            Both authority fields are required only when the claim was disallowed.
          </p>
        </div>
        <div style="margin-top:16px">
          <.button type="submit" variant="primary" phx-disable-with="Recording…">
            Record resolution
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("resolve", %{"claim_id" => claim_id, "resolution" => params}, socket) do
    with {claim_id, ""} <- Integer.parse(claim_id),
         {:ok, claim} <- fetch_claim(socket.assigns.claims, claim_id) do
      case Accounting.resolve_tax_deduction_claim(socket.assigns.current_scope, claim_id, params) do
        {:ok, _resolved} ->
          claims = Accounting.list_candidate_tax_deduction_claims(socket.assigns.current_scope)

          {:noreply,
           socket
           |> assign(:claims, claims)
           |> assign(:resolution_forms, resolution_forms(claims))
           |> put_flash(:info, "Tax claim resolution recorded")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           assign(
             socket,
             :resolution_forms,
             Map.put(
               socket.assigns.resolution_forms,
               claim.id,
               to_form(%{changeset | action: :update}, as: :resolution)
             )
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Tax deduction claim not found")}
    end
  end

  def handle_event("resolve", _params, socket) do
    {:noreply, put_flash(socket, :error, "Tax deduction claim not found")}
  end

  defp resolution_forms(claims) do
    Map.new(claims, fn claim ->
      {claim.id, resolution_form(claim)}
    end)
  end

  defp resolution_form(claim) do
    claim
    |> TaxDeductionClaim.changeset_for_resolution(%{"status" => "claimed"})
    |> to_form(as: :resolution)
  end

  defp fetch_claim(claims, claim_id) do
    case Enum.find(claims, &(&1.id == claim_id)) do
      nil -> :error
      claim -> {:ok, claim}
    end
  end

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
