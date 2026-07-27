defmodule ZaimuTomo.DocumentsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ZaimuTomo.Documents` context.
  """

  @doc """
  Generate a document.
  """
  def document_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        filename: "some filename",
        filepath: "some filepath"
      })

    {:ok, document} =
      %ZaimuTomo.Documents.Document{}
      |> ZaimuTomo.Documents.Document.changeset(attrs, scope)
      |> ZaimuTomo.Repo.insert()

    document
  end
end
