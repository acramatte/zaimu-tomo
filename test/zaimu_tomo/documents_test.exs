defmodule ZaimuTomo.DocumentsTest do
  use ZaimuTomo.DataCase

  alias ZaimuTomo.Documents
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)
  end

  describe "documents" do
    alias ZaimuTomo.Documents.Document

    import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
    import ZaimuTomo.DocumentsFixtures

    @invalid_attrs %{filename: nil, object_key: nil}

    test "list_documents/1 returns all scoped documents" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      document = document_fixture(scope)
      other_document = document_fixture(other_scope)
      assert [%{id: id}] = Documents.list_documents(scope)
      assert id == document.id
      assert [%{id: other_id}] = Documents.list_documents(other_scope)
      assert other_id == other_document.id
    end

    test "get_document!/2 returns the document with given id" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      other_scope = user_scope_fixture()
      assert Documents.get_document!(scope, document.id) == document

      assert_raise Ecto.NoResultsError, fn ->
        Documents.get_document!(other_scope, document.id)
      end
    end

    test "create_document/2 with valid data creates a document" do
      valid_attrs = %{filename: "some filename", object_key: "documents/some-file.pdf"}
      scope = user_scope_fixture()

      assert {:ok, %Document{} = document} = Documents.create_document(scope, valid_attrs)
      assert document.filename == "some filename"
      assert document.object_key == "documents/some-file.pdf"
      assert document.user_id == scope.user.id

      assert_eventually(fn ->
        ExtractedContentContext.get_latest_by_document(document.id) != nil
      end)
    end

    test "object_key_for/1 preserves the uploaded file extension" do
      object_key = Documents.object_key_for("receipt.pdf")
      assert String.starts_with?(object_key, "documents/")
      assert String.ends_with?(object_key, ".pdf")

      uuid =
        object_key
        |> String.trim_leading("documents/")
        |> String.trim_trailing(".pdf")

      assert Ecto.UUID.cast(uuid) != :error
    end

    test "create_document/2 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(scope, @invalid_attrs)
    end

    test "update_document/3 with valid data updates the document" do
      scope = user_scope_fixture()
      document = document_fixture(scope)

      update_attrs = %{
        filename: "some updated filename",
        object_key: "documents/updated-file.pdf"
      }

      assert {:ok, %Document{} = document} =
               Documents.update_document(scope, document, update_attrs)

      assert document.filename == "some updated filename"
      assert document.object_key == "documents/updated-file.pdf"
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

      assert {:error, %Ecto.Changeset{}} =
               Documents.update_document(scope, document, @invalid_attrs)

      assert Documents.get_document!(scope, document.id).id == document.id
    end

    test "delete_document/2 deletes the document" do
      scope = user_scope_fixture()
      document = document_fixture(scope)
      assert {:ok, object_key} = Storage.put_object(document.object_key, "invoice bytes")
      assert object_key == document.object_key

      assert {:ok, %Document{}} = Documents.delete_document(scope, document)
      assert_raise Ecto.NoResultsError, fn -> Documents.get_document!(scope, document.id) end
      assert {:error, :not_found} = Storage.head_object(document.object_key)
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("expected condition to become true")
end
