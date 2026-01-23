defmodule Ledgemechanicus.Documents do
  @moduledoc """
  The Documents context.
  """

  import Ecto.Query, warn: false
  alias Ledgemechanicus.Repo

  alias Ledgemechanicus.Documents.Document
  alias Ledgemechanicus.Accounts.Scope

  @doc """
  Subscribes to scoped notifications about any document changes.

  The broadcasted messages match the pattern:

    * {:created, %Document{}}
    * {:updated, %Document{}}
    * {:deleted, %Document{}}

  """
  def subscribe_documents(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(Ledgemechanicus.PubSub, "user:#{key}:documents")
  end

  defp broadcast_document(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(Ledgemechanicus.PubSub, "user:#{key}:documents", message)
  end

  @doc """
  Returns the list of documents.

  ## Examples

      iex> list_documents(scope)
      [%Document{}, ...]

  """
  def list_documents(%Scope{} = scope) do
    Repo.all_by(Document, user_id: scope.user.id)
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
  Creates a document.

  ## Examples

      iex> create_document(scope, %{field: value})
      {:ok, %Document{}}

      iex> create_document(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_document(%Scope{} = scope, attrs) do
    with {:ok, document = %Document{}} <-
           %Document{}
           |> Document.changeset(attrs, scope)
           |> Repo.insert() do
      broadcast_document(scope, {:created, document})
      {:ok, document}
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

    with {:ok, document = %Document{}} <-
           Repo.delete(document) do
      broadcast_document(scope, {:deleted, document})
      {:ok, document}
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
