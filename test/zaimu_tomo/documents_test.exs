defmodule ZaimuTomo.DocumentsTest do
  use ZaimuTomo.DataCase
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents
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

    test "create_document/2 with valid data creates a document and enqueues one job" do
      valid_attrs = %{filename: "some filename", object_key: "documents/some-file.pdf"}
      scope = user_scope_fixture()

      assert {:ok, %Document{} = document} = Documents.create_document(scope, valid_attrs)
      assert document.filename == "some filename"
      assert document.object_key == "documents/some-file.pdf"
      assert document.user_id == scope.user.id

      assert_enqueued(worker: OCRJob, args: %{document_id: document.id, currency_hint: "CHF"})
      assert [_] = all_enqueued(worker: OCRJob)
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

  describe "fingerprints" do
    alias ZaimuTomo.Documents.Document
    alias ZaimuTomo.Documents.Fingerprint

    import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
    import ZaimuTomo.DocumentsFixtures

    # Published SHA-256 test vector (FIPS 180-2) and its one-byte neighbour.
    @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    @abd_sha256 "a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9"

    test "sha256/1 encodes the exact bytes as 64 lowercase hex characters" do
      assert Fingerprint.sha256("abc") == @abc_sha256
      assert Fingerprint.sha256(["a", ["b"], "c"]) == @abc_sha256
      assert Fingerprint.sha256("abd") == @abd_sha256
      assert Fingerprint.sha256(<<0xFF, 0x00>>) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "store_upload/2 stores the bytes and returns the digest of the same bytes" do
      path = temp_upload("abc")

      assert {:ok, %{object_key: object_key, filename: "bill.pdf", content_sha256: @abc_sha256}} =
               Documents.store_upload(path, "bill.pdf")

      assert "documents/" <> _ = object_key
      assert String.ends_with?(object_key, ".pdf")
      assert {:ok, "abc"} = Storage.read_object(object_key)
    end

    test "store_upload/2 stores nothing when the upload cannot be read" do
      missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")

      assert {:error, :enoent} = Documents.store_upload(missing, "bill.pdf")
      assert [] = :ets.tab2list(Memory)
    end

    test "create_document/2 persists the digest" do
      scope = user_scope_fixture()

      assert {:ok, document} =
               Documents.create_document(scope, %{
                 filename: "bill.pdf",
                 object_key: "documents/bill.pdf",
                 content_sha256: @abc_sha256
               })

      assert Repo.reload!(document).content_sha256 == @abc_sha256
    end

    test "the changeset rejects a digest that is not 64 lowercase hex characters" do
      scope = user_scope_fixture()
      attrs = %{filename: "bill.pdf", object_key: "documents/bill.pdf"}

      for bad <- [String.upcase(@abc_sha256), String.slice(@abc_sha256, 0, 63), "not-a-digest"] do
        changeset = Document.changeset(%Document{}, Map.put(attrs, :content_sha256, bad), scope)
        assert %{content_sha256: ["has invalid format"]} = errors_on(changeset)
      end
    end

    test "a metadata-only update preserves the digest" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{content_sha256: @abc_sha256})

      assert {:ok, updated} =
               Documents.update_document(scope, document, %{filename: "renamed.pdf"})

      assert Repo.reload!(updated).content_sha256 == @abc_sha256
    end

    test "replacing the object updates the digest with the key" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{content_sha256: @abc_sha256})

      assert {:ok, updated} =
               Documents.update_document(scope, document, %{
                 object_key: "documents/replacement.pdf",
                 content_sha256: @abd_sha256
               })

      assert Repo.reload!(updated).content_sha256 == @abd_sha256
    end

    test "replacing the object without a new digest clears the stale digest" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{content_sha256: @abc_sha256})

      assert {:ok, updated} =
               Documents.update_document(scope, document, %{object_key: "documents/other.pdf"})

      assert Repo.reload!(updated).content_sha256 == nil
    end

    defp temp_upload(bytes) do
      path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)
      path
    end
  end
end
