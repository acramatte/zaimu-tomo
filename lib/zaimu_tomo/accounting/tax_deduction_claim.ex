defmodule ZaimuTomo.Accounting.TaxDeductionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.User

  @statuses ["undecided", "candidate", "not_deductible", "claimed", "disallowed"]

  schema "tax_deduction_claims" do
    field :tax_year, :integer
    field :status, :string, default: "undecided"
    field :category, :string
    field :deductible_amount_cents, :integer
    field :notes, :string

    belongs_to :journal_entry, JournalEntry
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset_for_create(%JournalEntry{} = entry, attrs) do
    %__MODULE__{
      journal_entry_id: entry.id,
      user_id: entry.user_id,
      tax_year: entry.date.year,
      deductible_amount_cents: entry.amount_cents
    }
    |> cast(attrs, [:status, :category, :deductible_amount_cents, :notes])
    |> validate_required([
      :journal_entry_id,
      :user_id,
      :tax_year,
      :status,
      :deductible_amount_cents
    ])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:journal_entry_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:journal_entry_id)
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
  end

  def changeset_for_update(%__MODULE__{} = claim, attrs) do
    claim
    |> cast(attrs, [:status, :category, :deductible_amount_cents, :notes])
    |> validate_required([:status, :deductible_amount_cents])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
  end

  def status_options do
    [
      {"Not yet decided", "undecided"},
      {"Potentially deductible", "candidate"},
      {"Not deductible", "not_deductible"}
    ]
  end

  def status_label("undecided"), do: "Not yet decided"
  def status_label("candidate"), do: "Potentially deductible"
  def status_label("not_deductible"), do: "Not deductible"
  def status_label("claimed"), do: "Included in tax return"
  def status_label("disallowed"), do: "Not allowed"
  def status_label(_), do: "—"
end
