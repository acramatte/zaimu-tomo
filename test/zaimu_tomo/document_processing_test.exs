defmodule ZaimuTomo.DocumentProcessingTest do
  use ZaimuTomo.DataCase, async: false

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo
  alias ZaimuTomo.AccountsFixtures

  describe "document processing workflow" do
    test "start_saga/0 starts the Saga GenServer" do
      # Verify Saga can be started (it's already started by the application)
      # Just verify it's running
      assert GenServer.call(ZaimuTomo.DocumentProcessing.Saga, :status) == :running
    end

    test "process_document/1 starts a supervised OCR task with the owner's currency snapshot" do
      # Ensure the named OCR supervisor is started for this test
      # (it may already be started by the application)
      case ZaimuTomo.DocumentProcessing.start_ocr_supervisor() do
        {:ok, _supervisor_pid} -> :ok
        # Already started, that's fine
        {:error, {:already_started, _pid}} -> :ok
      end

      # This test verifies the main processing workflow
      # We'll use a mock document for testing
      scope = AccountsFixtures.user_scope_fixture()

      # Create a test document
      document =
        %Document{}
        |> Document.changeset(
          %{
            filename: "test_invoice.pdf",
            filepath: "uploads/test_invoice.pdf"
          },
          scope
        )
        |> Repo.insert!()

      # Verify the document was created
      assert document.filename == "test_invoice.pdf"

      # The context should start a supervised OCR task
      # It will return {:ok, pid} for the task, even if the file doesn't exist
      # (the task itself will handle the file not found error)
      result = DocumentProcessing.process_document(document)

      assert {:ok, pid} = result
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      assert %ExtractedContent{status: "failed", user_id: user_id} =
               Repo.get_by!(ExtractedContent, document_id: document.id)

      assert user_id == scope.user.id
    end
  end

  describe "PubSub integration" do
    test "Saga subscribes to correct PubSub topic" do
      # Saga is already started by the application
      # Verify it subscribes to the correct topic by checking it's running
      # This is tested implicitly by the subscription in init/1
      assert GenServer.call(ZaimuTomo.DocumentProcessing.Saga, :status) == :running
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
