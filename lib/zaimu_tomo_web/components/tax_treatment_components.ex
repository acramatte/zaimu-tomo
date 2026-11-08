defmodule ZaimuTomoWeb.TaxTreatmentComponents do
  @moduledoc """
  The "Revise tax treatment" form on the journal entry page
  (`ZaimuTomoWeb.JournalEntryLive.Show`), which handles its
  `revise_tax_treatment` event with `revision_attrs/1` and
  `ZaimuTomo.Accounting.revise_tax_deduction_claim/3`.
  """
  use Phoenix.Component

  import ZaimuTomoWeb.CoreComponents, only: [input: 1]

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.TaxDeductionClaim

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
        "reason" => claim.notes
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
    fields = %{status: :status, deductible_amount_cents: :deductible_amount, notes: :reason}

    errors
    |> Enum.flat_map(fn {field, error} ->
      if field = fields[field], do: [{field, error}], else: []
    end)
    |> then(&error_form(params, &1))
  end

  defp error_form(params, errors),
    do: to_form(params, as: :tax_revision, errors: errors, action: :validate)

  @doc """
  Converts submitted form params into attrs for
  `Accounting.revise_tax_deduction_claim/3`.

  The amount is entered in currency units; a blank amount falls back to the
  context default. Returns `:error` for an amount that is not a
  number with at most two decimals.
  """
  @spec revision_attrs(map()) :: {:ok, map()} | :error
  def revision_attrs(params) when is_map(params) do
    with {:ok, cents} <- amount_to_cents(Map.get(params, "deductible_amount")) do
      {:ok,
       %{
         "status" => Map.get(params, "status"),
         "reason" => Map.get(params, "reason"),
         "deductible_amount_cents" => cents
       }}
    end
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :currency, :string, default: nil

  def tax_revision_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="tax-revision-form"
      phx-submit="revise_tax_treatment"
      class="tax-revision-form"
    >
      <div class="card-title" style="font-size:13px;margin-bottom:6px">Revise tax treatment</div>
      <p class="muted" style="font-size:12px;margin-bottom:10px">
        Record what was filed or what the tax office decided. Each revision is kept in the
        invoice's history.
      </p>
      <div style="display:grid;gap:10px">
        <.input
          field={@form[:status]}
          id="tax-revision-form-status"
          type="select"
          label="Tax treatment"
          options={TaxDeductionClaim.revision_status_options()}
        />
        <.input
          field={@form[:deductible_amount]}
          id="tax-revision-form-amount"
          type="number"
          step="0.01"
          inputmode="decimal"
          label={"Deductible amount#{if @currency, do: " (#{@currency})"}"}
        />
        <p class="muted" style="font-size:12px;margin-top:-6px">
          Set to 0 automatically for “Not deductible” and “Not allowed”.
        </p>
        <.input
          field={@form[:reason]}
          id="tax-revision-form-reason"
          type="textarea"
          label="Reason (optional)"
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
        if String.match?(trimmed, ~r/\A-?\d+(?:\.\d{1,2})?\z/) do
          {:ok, trimmed |> Decimal.new() |> Decimal.mult(100) |> Decimal.to_integer()}
        else
          :error
        end
    end
  end

  defp amount_to_cents(_amount), do: :error
end
