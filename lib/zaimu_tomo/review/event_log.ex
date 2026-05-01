defmodule ZaimuTomo.Review.EventLog do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Accounts.User

  schema "event_logs" do
    field :event_type, :string
    field :invoice_id, :string
    field :metadata, :map
    field :status, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset_for_create(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
        :event_type,
        :invoice_id,
        :user_id,
        :metadata,
        :status
      ])
    |> validate_required([:event_type, :metadata])
    |> validate_inclusion(:status, ["pending", "completed", "failed"])
    |> foreign_key_constraint(:user_id)
  end
end
