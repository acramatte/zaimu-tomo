defmodule ZaimuTomoWeb.TaxClaimLive.Index do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tax claims")
     |> assign(:current_path, "/tax_claims")
     |> assign(:years, [])
     |> assign(:tax_year, nil)
     |> assign(:claims_by_status, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    years = Accounting.list_tax_deduction_claim_years(socket.assigns.current_scope)
    tax_year = selected_tax_year(params, years)

    claims_by_status =
      case tax_year do
        nil ->
          %{}

        year ->
          Accounting.list_tax_deduction_claims(socket.assigns.current_scope, year)
          |> Enum.group_by(& &1.status)
      end

    {:noreply,
     socket
     |> assign(:years, years)
     |> assign(:tax_year, tax_year)
     |> assign(:claims_by_status, claims_by_status)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-title-row">
      <div>
        <h1 class="view-title">Tax claims</h1>
        <p class="view-sub">
          Review deductions by tax year, record their tax return, and retain any authority decision.
        </p>
      </div>
    </div>

    <div
      :if={@years != []}
      id="tax-claim-years"
      style="display:flex;flex-wrap:wrap;gap:8px;margin:20px 0"
    >
      <a
        :for={year <- @years}
        class={["btn sm", year == @tax_year && "primary"]}
        href={~p"/tax_claims?#{[tax_year: year]}"}
      >
        {year}
      </a>
    </div>

    <div :if={@tax_year == nil} id="tax-claims-empty" class="card empty-state">
      <div class="h">No tax claims yet</div>
      <div class="muted">
        Mark a posted journal entry as potentially deductible to review it in its tax year.
      </div>
    </div>

    <div :if={@tax_year != nil} class="grid grid-12" style="gap:16px">
      <.claim_section
        title="To review"
        description="Potential deductions awaiting your filing decision."
        claims={Map.get(@claims_by_status, "candidate", [])}
        empty_message="No candidate claims for this tax year."
      />
      <.claim_section
        title="Included in return"
        description="Claims recorded in your tax return and awaiting any authority response."
        claims={Map.get(@claims_by_status, "claimed", [])}
        empty_message="No claims recorded in the return."
      />
      <.claim_section
        title="Not claimed"
        description="Expenses you decided were not deductible."
        claims={Map.get(@claims_by_status, "not_deductible", [])}
        empty_message="No deductions marked not deductible."
      />
      <.claim_section
        title="Authority follow-up"
        description="Claims disallowed by a tax authority, with their decision reference."
        claims={Map.get(@claims_by_status, "disallowed", [])}
        empty_message="No authority decisions recorded."
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :claims, :list, required: true
  attr :empty_message, :string, required: true

  defp claim_section(assigns) do
    ~H"""
    <section class="card span-6">
      <div class="card-head">
        <div>
          <div class="card-title">{@title}</div>
          <div class="card-meta">{@description}</div>
        </div>
        <div class="num">{length(@claims)}</div>
      </div>
      <p :if={@claims == []} class="muted" style="font-size:13px">{@empty_message}</p>
      <a
        :for={claim <- @claims}
        id={"tax-claim-#{claim.id}"}
        class="detail-row"
        href={~p"/tax_claims/#{claim.id}"}
        style="display:block;text-decoration:none"
      >
        <% entry = claim.journal_entry %>
        <div style="display:flex;justify-content:space-between;gap:12px">
          <div>
            <div style="font-weight:600">{entry.issuer || "Unknown issuer"}</div>
            <div class="muted" style="font-size:12px">
              {entry.invoice_number || entry.description || "—"} · {format_date(entry.date)}
            </div>
          </div>
          <div class="num">
            {if claim.deductible_amount_cents && entry.currency,
              do: fmt_cents(claim.deductible_amount_cents, entry.currency),
              else: "—"}
          </div>
        </div>
        <div class="muted" style="font-size:12px;margin-top:4px">
          {TaxDeductionClaim.status_label(claim.status)}
        </div>
      </a>
    </section>
    """
  end

  defp selected_tax_year(%{"tax_year" => year}, years) do
    case Integer.parse(year) do
      {year, ""} -> if year in years, do: year, else: List.first(years)
      _ -> List.first(years)
    end
  end

  defp selected_tax_year(_params, years), do: List.first(years)

  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: "—"
end
