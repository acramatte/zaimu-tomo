defmodule Ledgemechanicus.DocumentsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Ledgemechanicus.Documents` context.
  """

  @doc """
  Generate a document.
  """
  def document_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        description: "some description",
        title: "some title",
        url: "some url"
      })

    {:ok, document} = Ledgemechanicus.Documents.create_document(scope, attrs)
    document
  end
end
