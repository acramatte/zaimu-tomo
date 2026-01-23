defmodule Ledgemechanicus.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  schema "documents" do
    field :title, :string
    field :description, :string
    field :url, :string
    field :user_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document, attrs, user_scope) do
    document
    |> cast(attrs, [:title, :description, :url])
    |> validate_required([:title, :description, :url])
    |> put_change(:user_id, user_scope.user.id)
  end
end
