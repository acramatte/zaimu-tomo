defmodule ZaimuTomo.Documents do
  @moduledoc """
  The Documents context.
  """

  import Ecto.Query, warn: false

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Documents.Fingerprint
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Storage

  @doc """
  Returns a portable object key for an uploaded file.
  """
  def object_key_for(filename) when is_binary(filename) do
    "documents/#{Ecto.UUID.generate()}#{Path.extname(filename)}"
  end

  @doc """
  Reads an uploaded file, stores its bytes, and fingerprints them.

  The SHA-256 is computed over the exact binary passed to
  `Storage.put_object/2`, so the returned key and digest always describe the
  same bytes. Returns attributes ready for `create_document/2` or
  `update_document/3`; the caller owns deleting the object if persisting the
  row fails.

  ## Examples

      iex> store_upload("/tmp/plug-123", "invoice.pdf")
      {:ok, %{object_key: "documents/….pdf", filename: "invoice.pdf", content_sha256: "…"}}

  """
  @spec store_upload(Path.t(), String.t()) ::
          {:ok, %{object_key: String.t(), filename: String.t(), content_sha256: String.t()}}
          | {:error, term()}
  def store_upload(path, filename) when is_binary(path) and is_binary(filename) do
    object_key = object_key_for(filename)

    with {:ok, body} <- File.read(path),
         content_sha256 = Fingerprint.sha256(body),
         {:ok, ^object_key} <- Storage.put_object(object_key, body) do
      {:ok, %{object_key: object_key, filename: filename, content_sha256: content_sha256}}
    else
      {:ok, _other_key} -> {:error, :unexpected_object_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Subscribes to scoped notifications about any document changes.

  The broadcasted messages match the pattern:

    * {:created, %Document{}}
    * {:updated, %Document{}}
    * {:deleted, %Document{}}

  """
  def subscribe_documents(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, documents_topic(scope))
  end

  defp broadcast_document(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, documents_topic(scope), message)
  end

  defp documents_topic(%Scope{} = scope), do: "user:#{scope.user.id}:documents"

  @doc """
  Returns the list of documents.

  ## Examples

      iex> list_documents(scope)
      [%Document{}, ...]

  """
  def list_documents(%Scope{} = scope) do
    ec_query =
      from ec in ExtractedContent,
        order_by: [desc: ec.inserted_at],
        preload: :review_decision

    from(d in Document,
      where: d.user_id == ^scope.user.id,
      order_by: [desc: d.inserted_at],
      preload: [extracted_content: ^ec_query]
    )
    |> Repo.all()
  end

  @doc """
  Returns every persisted document object key in a stable order.

  This is intentionally unscoped because storage maintenance commands verify
  the complete document collection.
  """
  def list_document_object_keys do
    from(d in Document,
      order_by: [asc: d.id],
      select: d.object_key
    )
    |> Repo.all()
  end

  @doc """
  Gets a single document.

  Raises `Ecto.NoResultsError` if the Document does not exist.

  ## Examples

      iex> get_document!(scope, 123)
      %Document{}

      iex> get_document!(scope, 456)
      ** (Ecto.NoResultsError)

  """
  def get_document!(%Scope{} = scope, id) do
    Repo.get_by!(Document, id: id, user_id: scope.user.id)
  end

  @doc """
  Fetches a document within the authenticated scope.

  Returns `{:error, :not_found}` when the document does not exist or belongs to
  another user, so callers can treat inaccessible documents as missing.

  ## Examples

      iex> fetch_document(scope, "123")
      {:ok, %Document{}}

      iex> fetch_document(scope, "999")
      {:error, :not_found}

  """
  def fetch_document(%Scope{} = scope, id) do
    case Repo.get_by(Document, id: id, user_id: scope.user.id) do
      nil -> {:error, :not_found}
      document -> {:ok, document}
    end
  end

  def get_document_with_content!(%Scope{} = scope, id) do
    ec_query =
      from ec in ExtractedContent,
        order_by: [desc: ec.inserted_at],
        preload: :review_decision

    Document
    |> Repo.get_by!(id: id, user_id: scope.user.id)
    |> Repo.preload(extracted_content: ec_query)
  end

  @doc """
  Creates a document.

  ## Examples

      iex> create_document(scope, %{field: value})
      {:ok, %Document{}}

      iex> create_document(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_document(%Scope{} = scope, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:document, Document.changeset(%Document{}, attrs, scope))
    |> Oban.insert(:ocr_job, fn %{document: document} ->
      DocumentProcessing.ocr_job(document, scope.user.base_currency, nil)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{document: document}} ->
        broadcast_document(scope, {:created, document})
        {:ok, document}

      {:error, :document, changeset, _changes} ->
        {:error, changeset}

      # Should not happen: the job insert runs in the same transaction and its
      # failure rolls back the document. Mapped to a changeset so upload callers
      # still clean up the stored object on any insert failure.
      {:error, :ocr_job, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a document.

  ## Examples

      iex> update_document(scope, document, %{field: new_value})
      {:ok, %Document{}}

      iex> update_document(scope, document, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_document(%Scope{} = scope, %Document{} = document, attrs) do
    true = document.user_id == scope.user.id

    with {:ok, document = %Document{}} <-
           document
           |> Document.changeset(attrs, scope)
           |> Repo.update() do
      broadcast_document(scope, {:updated, document})
      {:ok, document}
    end
  end

  @doc """
  Deletes a document.

  ## Examples

      iex> delete_document(scope, document)
      {:ok, %Document{}}

      iex> delete_document(scope, document)
      {:error, %Ecto.Changeset{}}

  """
  def delete_document(%Scope{} = scope, %Document{} = document) do
    true = document.user_id == scope.user.id

    document
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :journal_entries_review_decision_id_fkey,
      message: "has a posted journal entry and cannot be deleted"
    )
    |> Repo.delete()
    |> case do
      {:ok, document} ->
        _ = Storage.delete_object(document.object_key)
        broadcast_document(scope, {:deleted, document})
        {:ok, document}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking document changes.

  ## Examples

      iex> change_document(scope, document)
      %Ecto.Changeset{data: %Document{}}

  """
  def change_document(%Scope{} = scope, %Document{} = document, attrs \\ %{}) do
    true = document.user_id == scope.user.id

    Document.changeset(document, attrs, scope)
  end
end
