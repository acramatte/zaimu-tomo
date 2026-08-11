defmodule ZaimuTomo.Accounting.TaxDeductionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.User

  @initial_statuses ["undecided", "candidate", "not_deductible"]
  @resolution_statuses ["claimed", "disallowed"]

  @typedoc "Tax deduction claim schema struct"
  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          tax_year: integer() | nil,
          status: String.t() | nil,
          category: String.t() | nil,
          deductible_amount_cents: integer() | nil,
          notes: String.t() | nil,
          tax_return_reference: String.t() | nil,
          authority_name: String.t() | nil,
          authority_reference: String.t() | nil,
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
    field :tax_return_reference, :string
    field :authority_name, :string
    field :authority_reference, :string

    belongs_to :journal_entry, JournalEntry
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @typep persisted_journal_entry :: %JournalEntry{
           id: integer(),
           amount_cents: integer(),
           date: Date.t(),
           user_id: integer()
         }

  @spec changeset_for_create(persisted_journal_entry(), map()) :: Ecto.Changeset.t(t())
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
    |> validate_inclusion(:status, @initial_statuses)
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
    |> validate_inclusion(:status, @initial_statuses)
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
  end

  @spec changeset_for_resolution(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_resolution(%__MODULE__{} = claim, attrs) do
    claim
    |> cast(attrs, [:status, :tax_return_reference, :authority_name, :authority_reference])
    |> trim_context_fields()
    |> validate_required(:status)
    |> validate_inclusion(:status, @resolution_statuses)
    |> validate_resolution_context()
    |> apply_resolution_effects()
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
    |> check_constraint(:tax_return_reference,
      name: :tax_deduction_claims_claimed_return_reference_check
    )
    |> check_constraint(:authority_name,
      name: :tax_deduction_claims_disallowed_authority_context_check
    )
  end

  @spec status_options() :: [{String.t(), String.t()}]
  def status_options do
    [
      {"Not yet decided", "undecided"},
      {"Potentially deductible", "candidate"},
      {"Not deductible", "not_deductible"}
    ]
  end

  @spec resolution_options() :: [{String.t(), String.t()}]
  def resolution_options do
    [
      {"Included in tax return", "claimed"},
      {"Disallowed by tax authority", "disallowed"}
    ]
  end

  @spec status_label(String.t() | nil) :: String.t()
  def status_label("undecided"), do: "Not yet decided"
  def status_label("candidate"), do: "Potentially deductible"
  def status_label("not_deductible"), do: "Not deductible"
  def status_label("claimed"), do: "Included in tax return"
  def status_label("disallowed"), do: "Not allowed"
  def status_label(_), do: "—"

  defp trim_context_fields(changeset) do
    Enum.reduce(
      [:tax_return_reference, :authority_name, :authority_reference],
      changeset,
      fn field, changeset ->
        update_change(changeset, field, fn
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> nil
              trimmed -> trimmed
            end

          value ->
            value
        end)
      end
    )
  end

  defp validate_resolution_context(changeset) do
    case get_field(changeset, :status) do
      "claimed" -> validate_required(changeset, :tax_return_reference)
      "disallowed" -> validate_required(changeset, [:authority_name, :authority_reference])
      _ -> changeset
    end
  end

  defp apply_resolution_effects(changeset) do
    case get_field(changeset, :status) do
      "claimed" ->
        changeset
        |> put_change(:authority_name, nil)
        |> put_change(:authority_reference, nil)

      "disallowed" ->
        changeset
        |> put_change(:deductible_amount_cents, 0)
        |> put_change(:tax_return_reference, nil)

      _ ->
        changeset
    end
  end
end
