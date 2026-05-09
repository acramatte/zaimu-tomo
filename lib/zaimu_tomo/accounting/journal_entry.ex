defmodule ZaimuTomo.Accounting.JournalEntry do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounts.User

  schema "journal_entries" do
    field :amount_cents, :integer
    field :currency, :string
    field :date, :date
    field :description, :string
    field :issuer, :string
    field :invoice_number, :string
    field :category, :string
    field :status, :string
    field :notes, :string

    belongs_to :review_decision, ReviewDecision
    belongs_to :user, User

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
    |> validate_required([:review_decision_id, :user_id, :amount_cents, :currency])
    |> validate_inclusion(:status, ["uncategorized", "posted"])
    |> foreign_key_constraint(:review_decision_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:review_decision_id)
  end

  def changeset_for_categorize(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:category, :notes, :status])
    |> validate_required([:category])
    |> validate_inclusion(:status, ["uncategorized", "posted"])
  end
end
