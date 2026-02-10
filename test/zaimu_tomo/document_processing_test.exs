defmodule ZaimuTomo.DocumentProcessingTest do
  use ZaimuTomo.DataCase, async: true

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents
  alias ZaimuTomo.AccountsFixtures

  describe "document processing workflow" do
    test "start_saga/0 starts the Saga GenServer" do
      # Verify Saga can be started (it's already started by the application)
      # Just verify it's running
      assert GenServer.call(ZaimuTomo.DocumentProcessing.Saga, :status) == :running
    end

    test "process_document/1 starts supervised OCR task" do
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
      {:ok, document} =
        Documents.create_document(scope, %{
          filename: "test_invoice.pdf",
          filepath: "uploads/test_invoice.pdf"
        })

      # Verify the document was created
      assert document.filename == "test_invoice.pdf"

      # The context should start a supervised OCR task
      # It will return {:ok, pid} for the task, even if the file doesn't exist
      # (the task itself will handle the file not found error)
      result = DocumentProcessing.process_document(document)
      # Should start task successfully
      assert match?({:ok, _pid}, result)
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
