defmodule ZaimuTomo.Accounting.JournalEntry do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.Currency
  alias ZaimuTomo.Review.ReviewDecision

  @need_or_want_values ["need", "want"]

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
  end

  def changeset_for_categorize(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:category, :need_or_want, :notes, :status])
    |> validate_required([:category, :need_or_want])
    |> validate_inclusion(:need_or_want, @need_or_want_values)
    |> validate_inclusion(:status, ["uncategorized", "posted"])
    |> check_constraint(:need_or_want, name: :journal_entries_need_or_want_check)
  end

  def need_or_want_values, do: @need_or_want_values
end
