defmodule ZaimuTomo.Review.ReviewDecision do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData

  schema "review_decisions" do
    embeds_one :original_data, ExtractedData
    embeds_one :decision_data, ExtractedData
    field :decision_type, :string
    field :rejection_reason, :string
    field :review_completed_at, :utc_datetime
    field :review_notes, :string
    field :review_status, :string

    belongs_to :extracted_content, ExtractedContent
    belongs_to :user, User
    has_one :journal_entry, ZaimuTomo.Accounting.JournalEntry

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @statuses ~w(pending approved amended rejected failed)
  @decisions ~w(approved amended rejected)

  def effective_data(%__MODULE__{} = decision) do
    decision.decision_data || decision.original_data || %ExtractedData{}
  end

  def changeset_for_create(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :extracted_content_id,
      :user_id,
      :review_status,
      :decision_type,
      :rejection_reason,
      :review_notes,
      :review_completed_at
    ])
    |> cast_embed(:original_data, with: &ExtractedData.embedded_changeset/2)
    |> cast_embed(:decision_data, with: &ExtractedData.embedded_changeset/2)
    |> validate_required([:extracted_content_id, :user_id, :review_status, :decision_type])
    |> validate_inclusion(:review_status, @statuses)
    |> validate_rejection_reason()
    |> check_constraint(:review_status, name: :review_decisions_review_status_check)
    |> foreign_key_constraint(:extracted_content_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  The only way a review changes state: a pending review is decided as
  approved, amended, or rejected, and that decision is final. Every other
  state is terminal, so deciding a review that is no longer pending is an
  error on `:review_status`.

  `attrs` may carry `:review_notes`, `:rejection_reason` (required to reject),
  and `:decision_data` (the amended invoice data). Callers that must not act
  on a stale read decide a row they hold locked; see `ZaimuTomo.Review`. A
  database trigger enforces the same rule for every writer, so a stale struct
  that still reads pending gets the `:review_status` error on update.
  """
  def decide_changeset(%__MODULE__{} = review_decision, to, attrs) when to in @decisions do
    review_decision
    |> cast(attrs, [:rejection_reason, :review_notes])
    |> cast_embed(:decision_data, with: &ExtractedData.embedded_changeset/2)
    |> change(
      review_status: to,
      decision_type: to,
      review_completed_at: DateTime.utc_now(:second)
    )
    |> validate_pending(review_decision)
    |> validate_rejection_reason()
    |> check_constraint(:rejection_reason, name: :review_decisions_rejected_reason_check)
    |> check_constraint(:review_status,
      name: :review_decisions_transition_check,
      message: "is already decided"
    )
  end

  defp validate_pending(changeset, %__MODULE__{review_status: "pending"}), do: changeset

  defp validate_pending(changeset, %__MODULE__{review_status: status}),
    do: add_error(changeset, :review_status, "is already %{status}", status: status)

  defp validate_rejection_reason(changeset) do
    if get_field(changeset, :review_status) == "rejected" do
      changeset
      |> validate_required(:rejection_reason)
      |> validate_length(:rejection_reason, max: 1000)
    else
      changeset
    end
  end
end
