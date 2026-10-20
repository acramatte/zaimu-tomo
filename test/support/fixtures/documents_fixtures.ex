defmodule ZaimuTomo.DocumentsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ZaimuTomo.Documents` context.
  """

  alias ZaimuTomo.Documents.Document

  @doc """
  Generate a document.
  """
  def document_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        filename: "some filename",
        object_key: "documents/some-file.pdf"
      })

    {:ok, document} =
      %Document{}
      |> Document.changeset(attrs, scope)
      |> ZaimuTomo.Repo.insert()

    document
  end
end
