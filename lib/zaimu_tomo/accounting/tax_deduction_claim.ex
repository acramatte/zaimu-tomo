defmodule ZaimuTomo.Accounting.TaxDeductionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.User

  @statuses ["undecided", "candidate", "not_deductible", "claimed", "disallowed"]
  @zero_deduction_statuses ["not_deductible", "disallowed"]
  # Column limits: deductible_amount_cents is a 4-byte integer, notes a varchar(255).
  # A credit note's entry amount, and so its default deductible amount, is negative.
  @min_amount_cents -2_147_483_648
  @max_amount_cents 2_147_483_647
  @notes_max_length 255

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
    |> validate_inclusion(:status, @statuses)
    |> validate_column_limits()
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
    |> validate_column_limits()
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
  end

  defp validate_column_limits(changeset) do
    changeset
    |> validate_number(:deductible_amount_cents,
      greater_than_or_equal_to: @min_amount_cents,
      less_than_or_equal_to: @max_amount_cents
    )
    |> validate_length(:notes, max: @notes_max_length)
  end

  @doc "True for a status that deducts nothing, so its claim always stores 0."
  @spec zero_deduction?(String.t() | nil) :: boolean()
  def zero_deduction?(status), do: status in @zero_deduction_statuses

  @doc """
  The deductible amount a claim stores: 0 for a status that deducts nothing,
  otherwise the given amount, or the entry amount when none is given.
  """
  @spec deductible_amount_cents(String.t() | nil, integer() | nil, integer()) :: integer()
  def deductible_amount_cents(status, amount_cents, entry_amount_cents) do
    cond do
      zero_deduction?(status) -> 0
      is_nil(amount_cents) -> entry_amount_cents
      true -> amount_cents
    end
  end

  @doc "Longest reason or note a claim can store."
  @spec notes_max_length() :: pos_integer()
  def notes_max_length, do: @notes_max_length

  @spec status_options() :: [{String.t(), String.t()}]
  def status_options do
    [
      {"Not yet decided", "undecided"},
      {"Potentially deductible", "candidate"},
      {"Not deductible", "not_deductible"}
    ]
  end

  @doc """
  All statuses, for revising a posted entry's claim once the tax return is
  filed or assessed. Posting offers only `status_options/0`.
  """
  @spec revision_status_options() :: [{String.t(), String.t()}]
  def revision_status_options do
    status_options() ++
      [
        {"Included in tax return", "claimed"},
        {"Not allowed", "disallowed"}
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
