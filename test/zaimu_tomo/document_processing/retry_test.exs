defmodule ZaimuTomo.DocumentProcessing.RetryTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]

  import ZaimuTomo.ReviewFixtures,
    only: [extracted_content_fixture: 2, extracted_content_fixture: 3]

  describe "processing_state/1" do
    test "a live job means :processing" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      assert {:ok, _job} = Oban.insert(DocumentProcessing.ocr_job(document, "CHF", nil))

      assert DocumentProcessing.processing_state(document) == :processing
    end

    test "a live job means :processing even when a failed row exists" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, scope.user, %{status: "failed"})
      assert {:ok, _job} = Oban.insert(DocumentProcessing.ocr_job(document, "CHF", nil))

      assert DocumentProcessing.processing_state(document) == :processing
    end

    test "no extraction and no live job means :stuck" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})

      assert DocumentProcessing.processing_state(document) == :stuck
    end

    test "a failed latest extraction and no live job means :failed" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, scope.user, %{status: "failed"})

      assert DocumentProcessing.processing_state(document) == :failed
    end

    test "a successful latest extraction and no live job means :extracted" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, scope.user)

      assert DocumentProcessing.processing_state(document) == :extracted
    end
  end

  describe "retry_document/2" do
    test ":failed enqueues a job that supersedes the failed row" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      failed = extracted_content_fixture(document, scope.user, %{status: "failed"})

      assert {:ok, %Oban.Job{}} = DocumentProcessing.retry_document(scope, document)

      assert_enqueued(
        worker: OCRJob,
        args: %{
          document_id: document.id,
          currency_hint: "CHF",
          supersedes_extraction_id: failed.id
        }
      )
    end

    test ":stuck enqueues a job with no supersedes id" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})

      assert {:ok, %Oban.Job{}} = DocumentProcessing.retry_document(scope, document)

      assert_enqueued(
        worker: OCRJob,
        args: %{document_id: document.id, currency_hint: "CHF", supersedes_extraction_id: nil}
      )
    end

    test "a double retry leaves exactly one job" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, scope.user, %{status: "failed"})

      assert {:ok, %Oban.Job{}} = DocumentProcessing.retry_document(scope, document)

      assert {:error, {:not_retryable, :processing}} =
               DocumentProcessing.retry_document(scope, document)

      assert [_] = all_enqueued(worker: OCRJob)
    end

    test "failed rows stay as history when a retry is enqueued" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      failed = extracted_content_fixture(document, scope.user, %{status: "failed"})

      assert {:ok, %Oban.Job{}} = DocumentProcessing.retry_document(scope, document)

      assert [%ExtractedContent{id: id}] = Repo.all(ExtractedContent)
      assert id == failed.id
    end

    test ":processing is not retryable" do
      scope = user_scope_fixture()

      {:ok, document} =
        Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

      assert {:error, {:not_retryable, :processing}} =
               DocumentProcessing.retry_document(scope, document)

      # Only the upload's own job exists.
      assert [_] = all_enqueued(worker: OCRJob)
    end

    test ":extracted is not retryable" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, scope.user)

      assert {:error, {:not_retryable, :extracted}} =
               DocumentProcessing.retry_document(scope, document)

      refute_enqueued(worker: OCRJob)
    end

    test "a foreign scope returns {:error, :not_found} and enqueues nothing" do
      owner_scope = user_scope_fixture()
      document = document_fixture(owner_scope, %{object_key: "documents/a.pdf"})
      extracted_content_fixture(document, owner_scope.user, %{status: "failed"})

      foreign_scope = user_scope_fixture()

      assert {:error, :not_found} = DocumentProcessing.retry_document(foreign_scope, document)
      refute_enqueued(worker: OCRJob)
    end
  end
end
