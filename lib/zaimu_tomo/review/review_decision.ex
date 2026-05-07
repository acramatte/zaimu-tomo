defmodule ZaimuTomo.Review.ReviewDecision do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Accounts.User

  schema "review_decisions" do
    field :decision_data, :map
    field :decision_type, :string
    field :original_data, :map
    field :review_completed_at, :utc_datetime
    field :review_notes, :string
    field :review_status, :string

    belongs_to :extracted_content, ExtractedContent
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset_for_create(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
        :extracted_content_id,
        :user_id,
        :review_status,
        :decision_type,
        :decision_data,
        :review_notes,
        :original_data,
        :review_completed_at
      ])
    |> validate_required([:extracted_content_id, :user_id, :review_status, :decision_type])
    |> validate_inclusion(:review_status, ["pending", "approved", "rejected", "amended", "failed"])
    |> foreign_key_constraint(:extracted_content_id)
    |> foreign_key_constraint(:user_id)
  end

  def changeset_for_update(%__MODULE__{} = review_decision, attrs) do
    review_decision
    |> cast(attrs, [
        :review_status,
        :decision_data,
        :review_notes,
        :decision_type,
        :review_completed_at
      ])
    |> validate_inclusion(:review_status, ["pending", "approved", "rejected", "amended", "failed"])
  end
end
