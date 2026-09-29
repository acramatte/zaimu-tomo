defmodule ZaimuTomo.DocumentProcessing.OCRJobTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]

  @req_stub __MODULE__

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")
    on_exit(fn -> Application.put_env(:zaimu_tomo, :langfuse, original_langfuse) end)

    :ok
  end

  setup {Req.Test, :verify_on_exit!}

  describe "enqueue on upload" do
    test "create_document/2 enqueues exactly one OCR job with the currency snapshot" do
      scope = user_scope_fixture()

      assert {:ok, document} =
               Documents.create_document(scope, %{
                 filename: "a.pdf",
                 object_key: "documents/a.pdf"
               })

      assert_enqueued(worker: OCRJob, args: %{document_id: document.id, currency_hint: "CHF"})
      assert [_] = all_enqueued(worker: OCRJob)
    end

    test "an invalid document enqueues no job and creates no row" do
      scope = user_scope_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Documents.create_document(scope, %{filename: nil, object_key: nil})

      refute_enqueued(worker: OCRJob)
      assert Repo.aggregate(Document, :count) == 0
    end
  end

  describe "uniqueness" do
    test "a duplicate live job for the same document is a conflict" do
      scope = user_scope_fixture()

      {:ok, document} =
        Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

      assert {:ok, %Oban.Job{conflict?: true}} =
               Oban.insert(DocumentProcessing.ocr_job(document, "CHF", nil))

      assert [_] = all_enqueued(worker: OCRJob)
    end
  end

  describe "perform/1 outcome matrix" do
    test "transient error retries without persisting a failed row or broadcasting" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})
      Storage.put_object("documents/invoice.pdf", "invoice bytes")
      stub_mistral(fn conn -> Plug.Conn.send_resp(conn, 429, "rate limited") end)

      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")

      args = args_for(document)
      assert {:error, _reason} = perform_job(OCRJob, args, attempt: 1, max_attempts: 5)

      assert Repo.aggregate(ExtractedContent, :count) == 0
      refute_received %{status: :failed}
    end

    test "the final attempt of a transient error writes exactly one failed row" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})
      Storage.put_object("documents/invoice.pdf", "invoice bytes")
      stub_mistral(fn conn -> Plug.Conn.send_resp(conn, 429, "rate limited") end)

      args = args_for(document)

      for attempt <- 1..4 do
        assert {:error, _reason} = perform_job(OCRJob, args, attempt: attempt, max_attempts: 5)
        assert Repo.aggregate(ExtractedContent, :count) == 0
      end

      assert :ok = perform_job(OCRJob, args, attempt: 5, max_attempts: 5)

      assert [%ExtractedContent{status: "failed"}] = Repo.all(ExtractedContent)
      assert [%ReviewDecision{review_status: "failed"}] = Repo.all(ReviewDecision)
    end

    test "a permanent error writes one failed row on the first attempt" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})
      Storage.put_object("documents/invoice.pdf", "invoice bytes")

      # A missing Mistral API key is a permanent config error (needs a deploy).
      original = Application.fetch_env!(:zaimu_tomo, :mistral)
      Application.put_env(:zaimu_tomo, :mistral, Keyword.put(original, :api_key, nil))
      on_exit(fn -> Application.put_env(:zaimu_tomo, :mistral, original) end)

      assert :ok = perform_job(OCRJob, args_for(document), attempt: 1, max_attempts: 5)

      assert [%ExtractedContent{status: "failed"}] = Repo.all(ExtractedContent)
    end

    test "a storage :not_found is permanent and writes one failed row" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/missing.pdf"})

      assert :ok = perform_job(OCRJob, args_for(document), attempt: 1, max_attempts: 5)

      assert [%ExtractedContent{status: "failed"}] = Repo.all(ExtractedContent)
    end

    test "a deleted document cancels the job without persisting" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})
      document_id = document.id
      {:ok, _} = Repo.delete(document)

      args = %{document_id: document_id, currency_hint: "CHF", supersedes_extraction_id: nil}
      assert {:cancel, :document_deleted} = perform_job(OCRJob, args, attempt: 1)

      assert Repo.aggregate(ExtractedContent, :count) == 0
    end

    test "a superseded job cancels as already processed" do
      scope = user_scope_fixture()
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})

      # Simulate an earlier attempt that already appended a row after enqueue.
      {:ok, _prior} =
        ExtractedContentContext.create_extracted_content(%{
          document_id: document.id,
          user_id: document.user_id,
          extracted_data: %{},
          status: "failed",
          error_details: %{"type" => "prior", "message" => "already recorded"}
        })

      # Args captured supersedes_extraction_id: nil (no extraction at enqueue).
      args = %{document_id: document.id, currency_hint: "CHF", supersedes_extraction_id: nil}
      assert {:cancel, :already_processed} = perform_job(OCRJob, args, attempt: 1)

      # No additional row was appended.
      assert [_] = Repo.all(ExtractedContent)
    end
  end

  defp args_for(document) do
    %{document_id: document.id, currency_hint: "CHF", supersedes_extraction_id: nil}
  end

  defp stub_mistral(response_fun) do
    original = Application.fetch_env!(:zaimu_tomo, :mistral)

    Application.put_env(
      :zaimu_tomo,
      :mistral,
      Keyword.merge(original, api_key: "test-key", req_options: [plug: {Req.Test, @req_stub}])
    )

    on_exit(fn -> Application.put_env(:zaimu_tomo, :mistral, original) end)
    Req.Test.stub(@req_stub, response_fun)
  end
end
