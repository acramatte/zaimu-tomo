defmodule ZaimuTomo.DocumentProcessingTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo
  alias ZaimuTomo.AccountsFixtures

  describe "ocr_job/3" do
    test "builds a self-contained command snapshotting the currency at enqueue time" do
      scope = AccountsFixtures.user_scope_fixture()

      document =
        %Document{}
        |> Document.changeset(%{filename: "a.pdf", object_key: "documents/a.pdf"}, scope)
        |> Repo.insert!()

      changeset = DocumentProcessing.ocr_job(document, "CHF", 42)
      assert %Ecto.Changeset{valid?: true} = changeset

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args[:document_id] == document.id
      assert args[:currency_hint] == "CHF"
      assert args[:supersedes_extraction_id] == 42
    end

    test "uses the documents queue" do
      scope = AccountsFixtures.user_scope_fixture()

      document =
        %Document{}
        |> Document.changeset(%{filename: "a.pdf", object_key: "documents/a.pdf"}, scope)
        |> Repo.insert!()

      changeset = DocumentProcessing.ocr_job(document, "CHF", nil)
      assert Ecto.Changeset.get_field(changeset, :queue) == "documents"
    end
  end

  describe "DocumentOCR processing" do
    test "DocumentOCR.process/1 handles file processing" do
      # Test with a non-existent file (should return error)
      result = ZaimuTomo.DocumentProcessing.DocumentOCR.process("non_existent_file.pdf")

      # Should return an error tuple
      assert match?({:error, _}, result)
    end
  end
end
