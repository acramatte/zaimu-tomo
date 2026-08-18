defmodule ZaimuTomo.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

  schema "documents" do
    field :filename, :string
    field :object_key, :string
    field :user_id, :id

    has_many :extracted_content, ExtractedContent

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document, attrs, user_scope) do
    document
    |> cast(attrs, [:filename, :object_key])
    |> validate_required([:filename, :object_key])
    |> put_change(:user_id, user_scope.user.id)
  end
end
