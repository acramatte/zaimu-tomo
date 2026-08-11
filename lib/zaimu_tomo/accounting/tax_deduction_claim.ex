defmodule ZaimuTomo.Accounting.TaxDeductionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.User

  @statuses ["undecided", "candidate", "not_deductible", "claimed", "disallowed"]

  @typedoc "Tax deduction claim schema struct"
  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          tax_year: integer() | nil,
          status: String.t() | nil,
          category: String.t() | nil,
          deductible_amount_cents: integer() | nil,
          notes: String.t() | nil,
          journal_entry_id: integer() | nil,
          user_id: integer() | nil,
          journal_entry: Ecto.Schema.belongs_to(JournalEntry.t()),
          user: Ecto.Schema.belongs_to(struct()),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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

  @spec changeset_for_create(JournalEntry.t(), map()) :: Ecto.Changeset.t(t())
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

  @spec changeset_for_update(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_update(%__MODULE__{} = claim, attrs) do
    claim
    |> cast(attrs, [:status, :category, :deductible_amount_cents, :notes])
    |> validate_required([:status, :deductible_amount_cents])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
  end

  @spec status_options() :: [{String.t(), String.t()}]
  def status_options do
    [
      {"Not yet decided", "undecided"},
      {"Potentially deductible", "candidate"},
      {"Not deductible", "not_deductible"}
    ]
  end

  @spec status_label(String.t() | nil) :: String.t()
  def status_label("undecided"), do: "Not yet decided"
  def status_label("candidate"), do: "Potentially deductible"
  def status_label("not_deductible"), do: "Not deductible"
  def status_label("claimed"), do: "Included in tax return"
  def status_label("disallowed"), do: "Not allowed"
  def status_label(_), do: "—"
end
