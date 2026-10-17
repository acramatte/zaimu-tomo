defmodule ZaimuTomo.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Fingerprint

  schema "documents" do
    field :filename, :string
    field :object_key, :string
    # Fingerprint of the bytes at `object_key`; nil for legacy rows until the
    # backfill reads them. Redacted so it never reaches logs.
    field :content_sha256, :string, redact: true
    field :user_id, :id

    has_many :extracted_content, ExtractedContent

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(document, attrs, user_scope) do
    document
    |> cast(attrs, [:filename, :object_key, :content_sha256])
    |> validate_required([:filename, :object_key])
    |> validate_format(:content_sha256, Fingerprint.format())
    |> clear_stale_fingerprint()
    |> put_change(:user_id, user_scope.user.id)
    |> foreign_key_constraint(:user_id)
  end

  # The digest describes the bytes at `object_key`. Replacing the object
  # without a new digest must not leave the old file's digest behind.
  defp clear_stale_fingerprint(changeset) do
    if changed?(changeset, :object_key) and not changed?(changeset, :content_sha256) do
      put_change(changeset, :content_sha256, nil)
    else
      changeset
    end
  end
end
