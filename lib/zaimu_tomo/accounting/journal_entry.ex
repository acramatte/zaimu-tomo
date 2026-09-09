defmodule ZaimuTomo.Accounting.JournalEntry do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.Currency
  alias ZaimuTomo.Review.ReviewDecision

  @need_or_want_values ["need", "want"]

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
      :status
    ])
    |> Currency.normalize_and_validate(:currency)
    |> validate_required([:review_decision_id, :user_id, :amount_cents, :currency, :date])
    |> validate_inclusion(:status, ["uncategorized", "posted"])
    |> foreign_key_constraint(:review_decision_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:review_decision_id)
    |> unique_constraint(:invoice_number,
      name: :journal_entries_user_issuer_number_unique_index,
      message: "has already been recorded for this issuer"
    )
  end

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
