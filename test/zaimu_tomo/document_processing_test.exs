defmodule ZaimuTomo.DocumentProcessingTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.ReviewFixtures,
    only: [extracted_content_fixture: 2, extracted_content_fixture: 3]

  alias ZaimuTomo.AccountsFixtures
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.Run
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

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

  describe "processing_states/1" do
    setup do
      scope = AccountsFixtures.user_scope_fixture()
      %{scope: scope, user: scope.user}
    end

    defp insert_document(scope, name) do
      %Document{}
      |> Document.changeset(%{filename: name, object_key: "documents/#{name}"}, scope)
      |> Repo.insert!()
    end

    defp count_queries(fun) do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:zaimu_tomo, :repo, :query],
        fn _event, _measure, _meta, _ -> send(test_pid, {ref, :query}) end,
        nil
      )

      result = fun.()
      :telemetry.detach(ref)
      {result, length(Stream.repeatedly(fn -> receive_query(ref) end) |> Enum.take_while(& &1))}
    end

    defp receive_query(ref) do
      receive do
        {^ref, :query} -> true
      after
        0 -> false
      end
    end

    test "classifies each durable state like processing_state/1", %{scope: scope, user: user} do
      live = insert_document(scope, "live.pdf")
      DocumentProcessing.ocr_job(live, "CHF", nil) |> Oban.insert!()

      stuck = insert_document(scope, "stuck.pdf")

      failed = insert_document(scope, "failed.pdf")
      extracted_content_fixture(failed, user, %{status: "failed"})

      rerun = insert_document(scope, "rerun.pdf")
      extracted_content_fixture(rerun, user, %{status: "failed"})
      DocumentProcessing.ocr_job(rerun, "CHF", nil) |> Oban.insert!()

      extracted = insert_document(scope, "extracted.pdf")
      extracted_content_fixture(extracted, user, %{status: "failed"})
      extracted_content_fixture(extracted, user)

      docs = [live, stuck, failed, rerun, extracted]
      states = DocumentProcessing.processing_states(Enum.map(docs, & &1.id))

      assert states == %{
               live.id => :processing,
               stuck.id => :stuck,
               failed.id => :failed,
               rerun.id => :processing,
               extracted.id => :extracted
             }

      for doc <- docs, do: assert(states[doc.id] == DocumentProcessing.processing_state(doc))
    end

    test "uses a bounded number of queries regardless of document count", %{scope: scope} do
      few = for n <- 1..2, do: insert_document(scope, "few#{n}.pdf")
      many = few ++ for n <- 1..20, do: insert_document(scope, "many#{n}.pdf")

      {_, few_queries} = count_queries(fn -> DocumentProcessing.processing_states(ids(few)) end)
      {_, many_queries} = count_queries(fn -> DocumentProcessing.processing_states(ids(many)) end)

      assert few_queries == 2
      assert many_queries == few_queries
    end

    defp ids(docs), do: Enum.map(docs, & &1.id)
  end

  describe "live_runs/1" do
    import Ecto.Query, only: [from: 2]

    setup do
      scope = AccountsFixtures.user_scope_fixture()
      %{scope: scope, user: scope.user}
    end

    defp uploaded_document(scope, name) do
      {:ok, document} =
        ZaimuTomo.Documents.create_document(scope, %{
          filename: name,
          object_key: "documents/#{name}"
        })

      document
    end

    defp update_job(document, fields) do
      {1, _} =
        from(j in Oban.Job, where: fragment("?->>'document_id' = ?", j.args, ^"#{document.id}"))
        |> Repo.update_all(set: fields)
    end

    test "a new upload is queued for its first attempt", %{scope: scope} do
      document = uploaded_document(scope, "new.pdf")

      assert %{} = runs = DocumentProcessing.live_runs([document.id])

      assert %Run{
               phase: :queued,
               attempt: 1,
               max_attempts: 5,
               last_error: nil,
               next_attempt_at: nil,
               trigger: :upload
             } = run = runs[document.id]

      refute Run.retrying?(run)
    end

    test "a failed attempt waits to retry with the reason it failed", %{scope: scope} do
      document = uploaded_document(scope, "retry.pdf")
      next_at = DateTime.add(DateTime.utc_now(), 20)

      update_job(document,
        state: "retryable",
        attempt: 1,
        scheduled_at: next_at,
        meta: %{"trigger" => "upload", "last_error" => "ocr_request_failed:http_503"}
      )

      assert %Run{
               phase: :waiting_to_retry,
               attempt: 2,
               last_error: "ocr_request_failed:http_503",
               next_attempt_at: ^next_at,
               trigger: :upload
             } = run = DocumentProcessing.live_runs([document.id])[document.id]

      assert Run.retrying?(run)
    end

    test "a running retry reports its attempt and the latest failure", %{scope: scope} do
      document = uploaded_document(scope, "running.pdf")

      update_job(document,
        state: "executing",
        attempt: 3,
        meta: %{"trigger" => "upload", "last_error" => "job_timeout"}
      )

      assert %Run{phase: :running, attempt: 3, last_error: "job_timeout", next_attempt_at: nil} =
               DocumentProcessing.live_runs([document.id])[document.id]
    end

    test "the last error is the stored failure code, never Oban's error text", %{scope: scope} do
      document = uploaded_document(scope, "no-code.pdf")

      error =
        "** (Oban.PerformError) ZaimuTomo.DocumentProcessing.OCRJob failed with " <>
          ~s({:error, "ocr_upload_failed:http_503"})

      update_job(document,
        state: "available",
        attempt: 1,
        errors: [%{"attempt" => 1, "at" => DateTime.utc_now(), "error" => error}]
      )

      assert %Run{phase: :queued, attempt: 2, last_error: nil} =
               DocumentProcessing.live_runs([document.id])[document.id]
    end

    test "a run started with Retry processing is a manual retry and tells open pages",
         %{scope: scope, user: user} do
      document = insert_document(scope, "failed.pdf")
      extracted_content_fixture(document, user, %{status: "failed"})
      DocumentProcessing.subscribe_events(scope)
      document_id = document.id

      assert {:ok, _job} = DocumentProcessing.retry_document(scope, document)
      assert_received %{document_id: ^document_id}

      assert %Run{trigger: :manual_retry, attempt: 1, phase: :queued} =
               run = DocumentProcessing.live_runs([document.id])[document.id]

      assert Run.retrying?(run)
    end

    test "uses one query regardless of document count", %{scope: scope} do
      few = for n <- 1..2, do: uploaded_document(scope, "few#{n}.pdf")
      many = few ++ for n <- 1..20, do: uploaded_document(scope, "many#{n}.pdf")

      {_, few_queries} = count_queries(fn -> DocumentProcessing.live_runs(ids(few)) end)
      {_, many_queries} = count_queries(fn -> DocumentProcessing.live_runs(ids(many)) end)

      assert few_queries == 1
      assert many_queries == few_queries
    end

    test "only live OCR jobs of the given documents are runs", %{scope: scope} do
      completed = uploaded_document(scope, "completed.pdf")
      update_job(completed, state: "completed")

      other = uploaded_document(scope, "not-asked.pdf")

      %{document_id: completed.id}
      |> Oban.Job.new(worker: "ZaimuTomo.TypeSafeVerification.Worker", queue: :typesafe)
      |> Oban.insert!()

      assert DocumentProcessing.live_runs([completed.id]) == %{}
      assert Map.keys(DocumentProcessing.live_runs([completed.id, other.id])) == [other.id]
      assert DocumentProcessing.live_runs([]) == %{}
    end
  end

  describe "DocumentOCR processing" do
    test "DocumentOCR.process/1 handles file processing" do
      # Test with a non-existent file (should return error)
      result = DocumentOCR.process("non_existent_file.pdf")

      # Should return an error tuple
      assert match?({:error, _}, result)
    end
  end
end
