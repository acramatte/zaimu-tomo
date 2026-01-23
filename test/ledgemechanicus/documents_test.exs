defmodule Ledgemechanicus.DocumentsTest do
  use Ledgemechanicus.DataCase

  alias Ledgemechanicus.Documents

  describe "documents" do
    alias Ledgemechanicus.Documents.Document

    import Ledgemechanicus.AccountsFixtures, only: [user_scope_fixture: 0]
    import Ledgemechanicus.DocumentsFixtures

    @invalid_attrs %{description: nil, title: nil, url: nil}

    test "list_documents/1 returns all scoped documents" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      document = document_fixture(scope)
      other_document = document_fixture(other_scope)
      assert Documents.list_documents(scope) == [document]
      assert Documents.list_documents(other_scope) == [other_document]
    end

    test "get_document!/2 returns the document with given id" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      other_scope = user_scope_fixture()
      assert Documents.get_document!(scope, document.id) == document
      assert_raise Ecto.NoResultsError, fn -> Documents.get_document!(other_scope, document.id) end
    end

    test "create_document/2 with valid data creates a document" do
      valid_attrs = %{description: "some description", title: "some title", url: "some url"}
      scope = user_scope_fixture()

      assert {:ok, %Document{} = document} = Documents.create_document(scope, valid_attrs)
      assert document.description == "some description"
      assert document.title == "some title"
      assert document.url == "some url"
      assert document.user_id == scope.user.id
    end

    test "create_document/2 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(scope, @invalid_attrs)
    end

    test "update_document/3 with valid data updates the document" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      update_attrs = %{description: "some updated description", title: "some updated title", url: "some updated url"}

      assert {:ok, %Document{} = document} = Documents.update_document(scope, document, update_attrs)
      assert document.description == "some updated description"
      assert document.title == "some updated title"
      assert document.url == "some updated url"
    end

    test "update_document/3 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      document = document_fixture(scope)

      assert_raise MatchError, fn ->
        Documents.update_document(other_scope, document, %{})
      end
    end

    test "update_document/3 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Documents.update_document(scope, document, @invalid_attrs)
      assert document == Documents.get_document!(scope, document.id)
    end

    test "delete_document/2 deletes the document" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      assert {:ok, %Document{}} = Documents.delete_document(scope, document)
      assert_raise Ecto.NoResultsError, fn -> Documents.get_document!(scope, document.id) end
    end

    test "delete_document/2 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      document = document_fixture(scope)
      assert_raise MatchError, fn -> Documents.delete_document(other_scope, document) end
    end

    test "change_document/2 returns a document changeset" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      assert %Ecto.Changeset{} = Documents.change_document(scope, document)
    end
  end
end
