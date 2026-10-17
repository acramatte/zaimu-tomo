defmodule ZaimuTomo.Accounting.JournalEntry do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.Currency
  alias ZaimuTomo.Documents.Fingerprint
  alias ZaimuTomo.Review.ReviewDecision

  @need_or_want_values ["need", "want"]
  @duplicate_invoice_index "journal_entries_user_issuer_number_unique_index"
  @duplicate_source_file_index "journal_entries_user_source_document_sha256_unique_index"

  @typedoc "Journal entry schema struct"
  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          amount_cents: integer() | nil,
          currency: String.t() | nil,
          date: Date.t() | nil,
          description: String.t() | nil,
          issuer: String.t() | nil,
          invoice_number: String.t() | nil,
          category: String.t() | nil,
          need_or_want: String.t() | nil,
          status: String.t() | nil,
          notes: String.t() | nil,
          source_document_sha256: String.t() | nil,
          source_file_reuse_confirmed: boolean(),
          review_decision_id: integer() | nil,
          user_id: integer() | nil,
          review_decision: Ecto.Schema.belongs_to(struct()),
          user: Ecto.Schema.belongs_to(struct()),
          tax_deduction_claim: Ecto.Schema.has_one(TaxDeductionClaim.t()),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "journal_entries" do
    field :amount_cents, :integer
    field :currency, :string
    field :date, :date
    field :description, :string
    field :issuer, :string
    field :invoice_number, :string
    field :category, :string
    field :need_or_want, :string
    field :status, :string
    field :notes, :string
    # Posting-time snapshot of the source document's fingerprint. Only the
    # one-off backfill may set it on an existing row (see the backfill module).
    field :source_document_sha256, :string, redact: true
    field :source_file_reuse_confirmed, :boolean, default: false

    belongs_to :review_decision, ReviewDecision
    belongs_to :user, User
    has_one :tax_deduction_claim, TaxDeductionClaim

    timestamps(type: :utc_datetime)
  end

  @spec changeset_for_create(map()) :: Ecto.Changeset.t(t())
  def changeset_for_create(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :review_decision_id,
      :user_id,
      :amount_cents,
      :currency,
      :date,
      :description,
      :issuer,
      :invoice_number,
      :status,
      :source_document_sha256,
      :source_file_reuse_confirmed
    ])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:review_decision_id, :user_id, :amount_cents, :currency, :date])
    |> validate_inclusion(:status, ["uncategorized", "posted"])
    |> foreign_key_constraint(:review_decision_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:review_decision_id)
    |> fingerprint_constraints()
    |> unique_constraint(:invoice_number,
      name: @duplicate_invoice_index,
      message: "has already been recorded for this issuer"
    )
  end

  @doc """
  Changeset for the historical fingerprint backfill: the only permitted update
  of `source_document_sha256` (and, for a human-resolved collision,
  `source_file_reuse_confirmed`) on an existing entry.
  """
  @spec changeset_for_fingerprint_backfill(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_fingerprint_backfill(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:source_document_sha256, :source_file_reuse_confirmed])
    |> validate_required([:source_document_sha256])
    |> fingerprint_constraints()
  end

  defp fingerprint_constraints(changeset) do
    changeset
    |> validate_format(:source_document_sha256, Fingerprint.format())
    |> unique_constraint(:source_document_sha256,
      name: @duplicate_source_file_index,
      message: "the same file has already been recorded"
    )
  end

  @doc "Name of the unique (user, issuer, invoice number) index."
  @spec duplicate_invoice_index() :: String.t()
  def duplicate_invoice_index, do: @duplicate_invoice_index

  @doc "Name of the unique (user, source file digest) index over unconfirmed postings."
  @spec duplicate_source_file_index() :: String.t()
  def duplicate_source_file_index, do: @duplicate_source_file_index

  @spec changeset_for_categorize(t(), map()) :: Ecto.Changeset.t(t())
  def changeset_for_categorize(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:category, :need_or_want, :notes, :status])
    |> validate_required([:category, :need_or_want])
    |> validate_inclusion(:need_or_want, @need_or_want_values)
    |> validate_inclusion(:status, ["uncategorized", "posted"])
    |> check_constraint(:need_or_want, name: :journal_entries_need_or_want_check)
  end

  @spec need_or_want_values() :: [String.t()]
  def need_or_want_values, do: @need_or_want_values
end
