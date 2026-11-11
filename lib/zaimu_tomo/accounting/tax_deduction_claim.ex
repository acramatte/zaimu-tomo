defmodule ZaimuTomo.Accounting.TaxDeductionClaim do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts.User

  @statuses ["undecided", "candidate", "not_deductible", "claimed", "disallowed"]
  @zero_deduction_statuses ["not_deductible", "disallowed"]
  # Before filing, a claim moves freely between these.
  @draft_statuses ["undecided", "candidate", "not_deductible"]
  # Moves that undo a filing or a refusal; each needs a reason.
  @corrections [{"claimed", "candidate"}, {"disallowed", "claimed"}]
  @reference_fields [:tax_return_reference, :authority_name, :authority_reference]
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
    entry
    |> new_for_entry()
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
    |> claim_constraints()
  end

  @doc """
  A new, unsaved claim for an entry, with the entry amount as its deductible
  amount.
  """
  @spec new_for_entry(persisted_journal_entry()) :: t()
  def new_for_entry(%JournalEntry{} = entry) do
    %__MODULE__{
      journal_entry_id: entry.id,
      user_id: entry.user_id,
      tax_year: entry.date.year,
      deductible_amount_cents: entry.amount_cents
    }
  end

  @doc """
  Changeset for revising a posted entry's claim, saved or new (see
  `new_for_entry/1`). It enforces the lifecycle in `next_statuses/1`:

    * `claimed` (included in a tax return) needs `tax_return_reference`.
    * `disallowed` (refused by the tax authority) needs `authority_name` and
      `authority_reference`, and keeps the return reference.
    * A correction (`claimed` → `candidate`, `disallowed` → `claimed`) needs a
      reason in `notes`.

  References that no longer apply to the new status are cleared.
  """
  @spec changeset_for_revision(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_revision(%__MODULE__{} = claim, attrs) do
    from = claim.status || "undecided"

    claim
    |> cast(attrs, [:status, :deductible_amount_cents, :notes | @reference_fields])
    |> validate_required([:status, :deductible_amount_cents])
    |> validate_inclusion(:status, @statuses)
    |> validate_transition(from)
    |> validate_references()
    |> validate_column_limits()
    |> claim_constraints()
  end

  @doc """
  Statuses a claim in `status` can be revised to, itself included. A claim
  with no status yet counts as `undecided`.
  """
  @spec next_statuses(String.t() | nil) :: [String.t()]
  def next_statuses(nil), do: next_statuses("undecided")
  def next_statuses("candidate"), do: @draft_statuses ++ ["claimed"]
  def next_statuses(status) when status in @draft_statuses, do: @draft_statuses
  def next_statuses("claimed"), do: ["claimed", "disallowed", "candidate"]
  def next_statuses("disallowed"), do: ["disallowed", "claimed"]
  def next_statuses(_status), do: []

  @doc "True for a move that undoes a filing or a refusal, which needs a reason."
  @spec correction?(String.t() | nil, String.t() | nil) :: boolean()
  def correction?(from, to), do: {from, to} in @corrections

  defp validate_transition(changeset, from) do
    to = get_field(changeset, :status)

    cond do
      changeset.errors[:status] ->
        changeset

      to not in next_statuses(from) ->
        add_error(
          changeset,
          :status,
          "can't change from “#{status_label(from)}” to “#{status_label(to)}”"
        )

      correction?(from, to) ->
        validate_required(changeset, [:notes],
          message: "is required to correct a filed or refused claim"
        )

      true ->
        changeset
    end
  end

  defp validate_references(changeset) do
    case get_field(changeset, :status) do
      "claimed" ->
        changeset
        |> change(authority_name: nil, authority_reference: nil)
        |> validate_required([:tax_return_reference])

      "disallowed" ->
        validate_required(changeset, [:authority_name, :authority_reference])

      _draft ->
        change(changeset, Map.new(@reference_fields, &{&1, nil}))
    end
  end

  defp claim_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:journal_entry_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:journal_entry_id)
    |> check_constraint(:status, name: :tax_deduction_claims_status_check)
    |> check_constraint(:tax_return_reference,
      name: :tax_deduction_claims_claimed_return_reference_check,
      message: "is required for a claim included in a tax return"
    )
    |> check_constraint(:authority_reference,
      name: :tax_deduction_claims_disallowed_authority_check,
      message: "and authority name are required for a refused claim"
    )
  end

  @spec changeset_for_update(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_update(%__MODULE__{} = claim, attrs) do
    claim
    |> cast(attrs, [:status, :category, :deductible_amount_cents, :notes])
    |> validate_required([:status, :deductible_amount_cents])
    |> validate_inclusion(:status, @statuses)
    |> validate_column_limits()
    |> claim_constraints()
  end

  defp validate_column_limits(changeset) do
    changeset
    |> validate_number(:deductible_amount_cents,
      greater_than_or_equal_to: @min_amount_cents,
      less_than_or_equal_to: @max_amount_cents
    )
    |> validate_length(:notes, max: @notes_max_length)
    |> then(fn changeset ->
      Enum.reduce(@reference_fields, changeset, &validate_length(&2, &1, max: 255))
    end)
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
  The statuses a claim in `status` can be revised to, as select options.
  Posting offers only `status_options/0`.
  """
  @spec revision_status_options(String.t() | nil) :: [{String.t(), String.t()}]
  def revision_status_options(status) do
    Enum.map(next_statuses(status), &{status_label(&1), &1})
  end

  @spec status_label(String.t() | nil) :: String.t()
  def status_label("undecided"), do: "Not yet decided"
  def status_label("candidate"), do: "Potentially deductible"
  def status_label("not_deductible"), do: "Not deductible"
  def status_label("claimed"), do: "Included in tax return"
  def status_label("disallowed"), do: "Not allowed"
  def status_label(_), do: "—"
end
