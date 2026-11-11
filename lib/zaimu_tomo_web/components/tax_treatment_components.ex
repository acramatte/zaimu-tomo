defmodule ZaimuTomoWeb.TaxTreatmentComponents do
  @moduledoc """
  The "Revise tax treatment" form on the journal entry page
  (`ZaimuTomoWeb.JournalEntryLive.Show`), which handles its
  `revise_tax_treatment` event with `revision_attrs/1` and
  `ZaimuTomo.Accounting.revise_tax_deduction_claim/3`, and its
  `change_tax_revision` event with `revision_form/1` on the params, so the
  reference fields follow the chosen status.
  """
  use Phoenix.Component

  import ZaimuTomoWeb.CoreComponents, only: [input: 1]

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim

  # Largest amount the 4-byte cents column stores; bigger inputs are rejected
  # here so the error speaks in currency units, not cents.
  @max_amount_cents 2_147_483_647

  @doc """
  Builds the revision form prefilled from the entry's current claim. After a
  status that deducts nothing, the amount is left blank, so choosing a
  deductible status again falls back to the entry amount instead of 0.
  """
  @spec revision_form(JournalEntry.t()) :: Phoenix.HTML.Form.t()
  def revision_form(%JournalEntry{tax_deduction_claim: claim} = entry) do
    claim = if match?(%TaxDeductionClaim{}, claim), do: claim, else: %TaxDeductionClaim{}

    amount =
      if TaxDeductionClaim.zero_deduction?(claim.status),
        do: nil,
        else: format_amount(claim.deductible_amount_cents || entry.amount_cents)

    to_form(
      %{
        "status" => claim.status || "undecided",
        "deductible_amount" => amount,
        "reason" => claim.notes,
        "tax_return_reference" => claim.tax_return_reference,
        "authority_name" => claim.authority_name,
        "authority_reference" => claim.authority_reference
      },
      as: :tax_revision
    )
  end

  @doc """
  Rebuilds the form from submitted params with inline errors, from either
  `revision_attrs/1` returning `:error` (`:invalid_amount`) or a changeset
  returned by `Accounting.revise_tax_deduction_claim/3`.
  """
  @spec revision_form(map(), :invalid_amount | Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def revision_form(params, :invalid_amount) when is_map(params) do
    error_form(params,
      deductible_amount: {"must be an amount with up to 2 decimals", []}
    )
  end

  def revision_form(params, %Ecto.Changeset{errors: errors}) when is_map(params) do
    fields = %{
      status: :status,
      deductible_amount_cents: :deductible_amount,
      notes: :reason,
      tax_return_reference: :tax_return_reference,
      authority_name: :authority_name,
      authority_reference: :authority_reference
    }

    errors
    |> Enum.flat_map(fn {field, error} ->
      if field = fields[field], do: [{field, error}], else: []
    end)
    |> then(&error_form(params, &1))
  end

  @doc "The form for submitted params without errors, after a status change."
  @spec changed_form(map()) :: Phoenix.HTML.Form.t()
  def changed_form(params) when is_map(params), do: to_form(params, as: :tax_revision)

  defp error_form(params, errors),
    do: to_form(params, as: :tax_revision, errors: errors, action: :validate)

  @doc """
  Converts submitted form params into attrs for
  `Accounting.revise_tax_deduction_claim/3`.

  The amount is entered in currency units; a blank amount falls back to the
  context default, and a status that deducts nothing ignores it. Returns
  `:error` for an amount that is not a number with at most two decimals.
  """
  @spec revision_attrs(map()) :: {:ok, map()} | :error
  def revision_attrs(params) when is_map(params) do
    amount =
      if TaxDeductionClaim.zero_deduction?(params["status"]),
        do: nil,
        else: Map.get(params, "deductible_amount")

    with {:ok, cents} <- amount_to_cents(amount) do
      {:ok,
       %{
         "status" => Map.get(params, "status"),
         "reason" => Map.get(params, "reason"),
         "deductible_amount_cents" => cents,
         "tax_return_reference" => Map.get(params, "tax_return_reference"),
         "authority_name" => Map.get(params, "authority_name"),
         "authority_reference" => Map.get(params, "authority_reference")
       }}
    end
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :current_status, :string, default: nil, doc: "the saved claim's status"
  attr :currency, :string, default: nil

  def tax_revision_form(assigns) do
    assigns =
      assign(assigns,
        status: assigns.form[:status].value,
        correction?:
          TaxDeductionClaim.correction?(
            assigns.current_status,
            assigns.form[:status].value
          )
      )

    ~H"""
    <.form
      for={@form}
      id="tax-revision-form"
      phx-change="change_tax_revision"
      phx-submit="revise_tax_treatment"
      class="tax-revision-form"
    >
      <div class="card-title" style="font-size:13px;margin-bottom:6px">Revise tax treatment</div>
      <p class="muted" style="font-size:12px;margin-bottom:10px">
        Record what was filed or what the tax office decided. Each revision is recorded with
        its reason in the audit log.
      </p>
      <div style="display:grid;gap:10px">
        <.input
          field={@form[:status]}
          id="tax-revision-form-status"
          type="select"
          label="Tax treatment"
          options={TaxDeductionClaim.revision_status_options(@current_status)}
        />
        <.input
          :if={@status in ["claimed", "disallowed"]}
          field={@form[:tax_return_reference]}
          id="tax-revision-form-return-reference"
          label="Tax return reference"
          maxlength="255"
          placeholder="e.g. 2026 return, filed 2027-03-01"
          readonly={@status == "disallowed"}
        />
        <.input
          :if={@status == "disallowed"}
          field={@form[:authority_name]}
          id="tax-revision-form-authority-name"
          label="Tax authority"
          maxlength="255"
          placeholder="e.g. Steuerverwaltung Kanton Zürich"
        />
        <.input
          :if={@status == "disallowed"}
          field={@form[:authority_reference]}
          id="tax-revision-form-authority-reference"
          label="Authority reference"
          maxlength="255"
          placeholder="e.g. assessment number"
        />
        <.input
          field={@form[:deductible_amount]}
          id="tax-revision-form-amount"
          inputmode="decimal"
          autocomplete="off"
          label={"Deductible amount#{if @currency, do: " (#{@currency})"}"}
        />
        <p class="muted" style="font-size:12px;margin-top:-6px">
          Set to 0 automatically for “Not deductible” and “Not allowed”.
        </p>
        <.input
          field={@form[:reason]}
          id="tax-revision-form-reason"
          type="textarea"
          label={if @correction?, do: "Reason (required for a correction)", else: "Reason (optional)"}
          maxlength={TaxDeductionClaim.notes_max_length()}
          placeholder="e.g. Tax office assessment of 2027-03-14"
        />
      </div>
      <div style="margin-top:12px">
        <button
          id="tax-revision-form-submit"
          type="submit"
          class="btn sm"
          phx-disable-with="Saving…"
        >
          Save revision
        </button>
      </div>
    </.form>
    """
  end

  defp format_amount(nil), do: nil

  defp format_amount(cents) when is_integer(cents) do
    cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2) |> Decimal.to_string(:normal)
  end

  defp amount_to_cents(nil), do: {:ok, nil}

  defp amount_to_cents(amount) when is_binary(amount) do
    case String.trim(amount) do
      "" ->
        {:ok, nil}

      trimmed ->
        # An optional minus sign is allowed for credit notes; the format rules out
        # exponents, NaN and Infinity before parsing.
        with true <- String.match?(trimmed, ~r/\A-?\d+(?:\.\d{1,2})?\z/),
             cents = trimmed |> Decimal.new() |> Decimal.mult(100) |> Decimal.to_integer(),
             true <- abs(cents) <= @max_amount_cents do
          {:ok, cents}
        else
          _ -> :error
        end
    end
  end

  defp amount_to_cents(_amount), do: :error
end
