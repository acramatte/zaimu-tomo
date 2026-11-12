defmodule ZaimuTomo.DocumentProcessing.AttemptOutcomesTest do
  use ZaimuTomo.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ZaimuTomo.Activity
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.AttemptOutcomes
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.DocumentProcessing.Run
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]
  import ZaimuTomo.ReviewFixtures, only: [extracted_content_fixture: 2, pending_review_fixture: 1]

  @req_stub __MODULE__

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")
    on_exit(fn -> Application.put_env(:zaimu_tomo, :langfuse, original_langfuse) end)

    original_mistral = Application.fetch_env!(:zaimu_tomo, :mistral)

    Application.put_env(
      :zaimu_tomo,
      :mistral,
      Keyword.merge(original_mistral,
        api_key: "test-key",
        req_options: [plug: {Req.Test, @req_stub}]
      )
    )

    on_exit(fn -> Application.put_env(:zaimu_tomo, :mistral, original_mistral) end)
  end

  # Stubs run in the job's process, which is not the test's when a real queue
  # runs the job.
  setup {Req.Test, :set_req_test_to_shared}
  setup {Req.Test, :verify_on_exit!}

  # An uploaded document with its OCR job, watched by its owner's pages.
  defp upload(_context) do
    scope = user_scope_fixture()

    {:ok, document} =
      Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

    Storage.put_object("documents/a.pdf", "invoice bytes")
    DocumentProcessing.subscribe_events(scope)

    %{scope: scope, document: document}
  end

  defp update_job(fields) do
    {1, _} = Repo.update_all(Oban.Job, set: fields)
    :ok
  end

  defp final_attempt(_context), do: update_job(max_attempts: 1)

  # A second Oban instance that runs for real, beside the manual test instance.
  defp start_oban!(opts) do
    start_supervised!(
      {Oban,
       Keyword.merge(
         [
           name: __MODULE__.Oban,
           repo: Repo,
           queues: [],
           plugins: [],
           stager: false,
           peer: Oban.Peers.Isolated,
           notifier: Oban.Notifiers.Isolated,
           testing: :disabled
         ],
         opts
       )}
    )
  end

  defp failed_message(document) do
    assert [%ExtractedContent{status: "failed", error_details: %{"message" => message}}] =
             Repo.all(from ec in ExtractedContent, where: ec.document_id == ^document.id)

    message
  end

  describe "an outcome the handler cannot process" do
    # :telemetry detaches a handler that raises, so handle_event/4 must not.
    test "is logged instead of raised" do
      job = %Oban.Job{worker: inspect(OCRJob), args: %{}, meta: %{}}

      log =
        capture_log(fn ->
          AttemptOutcomes.handle_event(
            [:oban, :job, :exception],
            %{},
            %{job: job, state: :failure, reason: %RuntimeError{message: "boom"}},
            nil
          )
        end)

      assert log =~ "Attempt outcome not handled"
    end
  end

  describe "failure_code/1" do
    test "an error return keeps the code OCRJob returned" do
      reason = Oban.PerformError.exception({OCRJob, {:error, "ocr_upload_failed:http_503"}})

      assert AttemptOutcomes.failure_code(reason) == "ocr_upload_failed:http_503"
    end

    test "the job timeout is job_timeout" do
      reason = Oban.TimeoutError.exception({OCRJob, :timer.minutes(10)})

      assert AttemptOutcomes.failure_code(reason) == "job_timeout"
    end

    test "a raise, a crash, an exit, or an error return without a code is unclassified" do
      for reason <- [
            %RuntimeError{message: "SECRET-INVOICE-TEXT"},
            Oban.CrashError.exception({:throw, "SECRET-INVOICE-TEXT", []}),
            :killed,
            Oban.PerformError.exception({OCRJob, {:error, %{body: "SECRET-INVOICE-TEXT"}}})
          ] do
        assert AttemptOutcomes.failure_code(reason) == "unclassified"
      end
    end
  end

  describe "a failed attempt with a retry ahead" do
    setup :upload

    test "stores its failure code on the job and tells only the owner's open pages",
         %{scope: scope, document: document} do
      other = user_scope_fixture()
      DocumentProcessing.subscribe_events(other)
      document_id = document.id
      user_id = scope.user.id
      Req.Test.stub(@req_stub, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      assert %{failure: 1} = Oban.drain_queue(queue: :documents)

      assert %Oban.Job{
               state: "retryable",
               meta: %{"trigger" => "upload", "last_error" => "ocr_upload_failed:http_503"}
             } = Repo.one!(Oban.Job)

      assert %{
               ^document_id => %Run{
                 phase: :waiting_to_retry,
                 attempt: 2,
                 last_error: "ocr_upload_failed:http_503"
               }
             } = DocumentProcessing.live_runs([document_id])

      assert_received %{status: :attempt_failed, document_id: ^document_id, user_id: ^user_id}
      refute_received %{status: :attempt_failed}
      refute_received %{status: :failed}
    end

    test "keeps the document where it was in the activity feed",
         %{scope: scope, document: document} do
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200)

      Repo.update_all(from(d in Documents.Document, where: d.id == ^document.id),
        set: [inserted_at: two_hours_ago, updated_at: two_hours_ago]
      )

      Repo.update_all(Oban.Job, set: [inserted_at: two_hours_ago])

      newer = document_fixture(scope, %{filename: "newer.pdf"})
      newer |> extracted_content_fixture(scope.user) |> pending_review_fixture()

      assert [%{filename: "newer.pdf"}, %{filename: "a.pdf"}] =
               Activity.list_recent(scope, limit: :all)

      Req.Test.stub(@req_stub, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      assert %{failure: 1} = Oban.drain_queue(queue: :documents)

      assert [
               %{filename: "newer.pdf"},
               %{filename: "a.pdf", run: %Run{phase: :waiting_to_retry, attempt: 2}}
             ] = Activity.list_recent(scope, limit: :all)
    end

    test "that raised reads unclassified, without the exception's text", %{document: document} do
      Req.Test.stub(@req_stub, fn _conn -> raise "SECRET-INVOICE-TEXT" end)

      assert %{failure: 1} = Oban.drain_queue(queue: :documents)

      assert %Run{phase: :waiting_to_retry, last_error: "unclassified"} =
               DocumentProcessing.live_runs([document.id])[document.id]

      assert_received %{status: :attempt_failed}
    end
  end

  describe "an attempt's outcome that arrives after a newer attempt started" do
    setup :upload

    test "leaves the newer attempt's job alone" do
      [job] = Repo.all(Oban.Job)
      update_job(state: "executing", attempt: 2, attempted_at: DateTime.utc_now())

      AttemptOutcomes.handle_event(
        [:oban, :job, :exception],
        %{},
        %{
          job: %{job | attempt: 1, attempted_at: DateTime.add(DateTime.utc_now(), -60)},
          state: :failure,
          reason: %Oban.PerformError{reason: {:error, "ocr_upload_failed:http_503"}},
          conf: Oban.config()
        },
        nil
      )

      assert %Oban.Job{meta: meta} = Repo.reload!(job)
      refute Map.has_key?(meta, "last_error")
      refute_received %{status: :attempt_failed}
    end
  end

  describe "a final attempt that raised" do
    setup [:upload, :final_attempt]

    test "records the failure with a reason the user can read and tells the owner's pages once",
         %{document: document} do
      document_id = document.id
      Req.Test.stub(@req_stub, fn _conn -> raise "SECRET-INVOICE-TEXT" end)

      assert %{discard: 1} = Oban.drain_queue(queue: :documents)

      assert failed_message(document) == "An unexpected error"
      assert [%ReviewDecision{review_status: "failed"}] = Repo.all(ReviewDecision)
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :failed}
      assert DocumentProcessing.live_runs([document_id]) == %{}

      assert_received %{status: :failed, document_id: ^document_id}
      refute_received %{status: :failed}
      refute_received %{status: :attempt_failed}
    end

    test "records nothing when the document was deleted during the run", %{document: document} do
      Req.Test.stub(@req_stub, fn _conn ->
        Repo.delete!(document)
        raise "boom"
      end)

      log = capture_log(fn -> assert %{discard: 1} = Oban.drain_queue(queue: :documents) end)

      assert Repo.aggregate(ExtractedContent, :count) == 0
      refute log =~ "Attempt outcome not handled"
      refute_received %{status: :failed}
    end

    test "records nothing when a newer run already wrote its row", %{document: document} do
      Req.Test.stub(@req_stub, fn _conn ->
        {:ok, _newer} =
          ExtractedContentContext.create_extracted_content(%{
            document_id: document.id,
            user_id: document.user_id,
            extracted_data: %{},
            status: "failed",
            error_details: %{"message" => "Recorded by the newer run"}
          })

        raise "boom"
      end)

      log = capture_log(fn -> assert %{discard: 1} = Oban.drain_queue(queue: :documents) end)

      assert failed_message(document) == "Recorded by the newer run"
      refute log =~ "Attempt outcome not handled"
      refute_received %{status: :failed}
    end
  end

  describe "a discarded final attempt whose outcome arrives after Retry processing" do
    setup [:upload, :final_attempt]

    test "records nothing, so the retry's run is not superseded",
         %{scope: scope, document: document} do
      document_id = document.id
      [discarded] = Repo.all(Oban.Job)
      update_job(state: "discarded", discarded_at: DateTime.utc_now())

      assert {:ok, retry} = DocumentProcessing.retry_document(scope, document)

      AttemptOutcomes.handle_event(
        [:oban, :job, :exception],
        %{},
        %{
          job: Repo.reload!(discarded),
          state: :discard,
          reason: %RuntimeError{message: "boom"},
          conf: Oban.config()
        },
        nil
      )

      assert Repo.aggregate(ExtractedContent, :count) == 0
      assert retry.args["supersedes_extraction_id"] == nil
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :processing}
      refute_received %{status: :failed}
    end
  end

  describe "a final attempt that hit the job timeout" do
    setup [:upload, :final_attempt]

    test "records the failure as taking too long", %{document: document} do
      document_id = document.id
      test_pid = self()

      Req.Test.stub(@req_stub, fn _conn ->
        send(test_pid, {:running, self()})
        Process.sleep(:infinity)
      end)

      start_oban!(queues: [documents: 1])
      Oban.Notifier.notify(__MODULE__.Oban, :insert, %{queue: "documents"})
      assert_receive {:running, job_pid}, 2_000

      # What Oban's timer does when OCRJob.timeout/1 runs out.
      Process.exit(job_pid, Oban.TimeoutError.exception({OCRJob, :timer.minutes(10)}))

      assert_receive %{status: :failed, document_id: ^document_id}, 2_000
      assert failed_message(document) == "The run took too long"
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :failed}
      assert %Oban.Job{state: "discarded"} = Repo.one!(Oban.Job)
      refute_received %{status: :attempt_failed}
    end
  end

  describe "a job Oban.Lifeline rescues after its node died" do
    setup :upload

    setup do
      update_job(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -1, :hour))
    end

    test "on its final attempt is recorded as interrupted", %{document: document} do
      document_id = document.id
      update_job(attempt: 5, max_attempts: 5)

      start_oban!(plugins: [{Oban.Lifeline, interval: 10, rescue_after: :timer.minutes(30)}])

      assert_receive %{status: :failed, document_id: ^document_id}, 2_000
      assert failed_message(document) == "The run was interrupted"
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :failed}
      assert %Oban.Job{state: "discarded"} = Repo.one!(Oban.Job)
    end

    test "that ran and failed again before the rescue was reported keeps the newer reason",
         %{document: document} do
      [job] = Repo.all(Oban.Job)

      update_job(
        state: "retryable",
        attempt: 3,
        attempted_at: DateTime.utc_now(),
        meta: Map.put(job.meta, "last_error", "ocr_upload_failed:http_503")
      )

      AttemptOutcomes.handle_event(
        [:oban, :plugin, :stop],
        %{},
        %{
          plugin: Oban.Lifeline,
          conf: Oban.config(),
          rescued_jobs: [%{id: job.id, queue: "documents", state: "available"}],
          discarded_jobs: []
        },
        nil
      )

      assert %Oban.Job{meta: %{"last_error" => "ocr_upload_failed:http_503"}} = Repo.reload!(job)
      refute_received %{status: :attempt_failed}
    end

    test "before its final attempt waits to retry with the reason", %{document: document} do
      document_id = document.id
      update_job(attempt: 2, max_attempts: 5)

      start_oban!(plugins: [{Oban.Lifeline, interval: 10, rescue_after: :timer.minutes(30)}])

      assert_receive %{status: :attempt_failed, document_id: ^document_id}, 2_000

      assert %Run{phase: :queued, attempt: 3, last_error: "job_interrupted"} =
               DocumentProcessing.live_runs([document_id])[document_id]

      assert Repo.aggregate(ExtractedContent, :count) == 0
    end
  end

  describe "a run whose failure could not be recorded" do
    setup :upload

    test "tells the owner's pages, which show the document as stalled", %{document: document} do
      document_id = document.id

      # A missing API key is a permanent error, so the first attempt records
      # the failure, and the review decision insert fails.
      mistral = Application.fetch_env!(:zaimu_tomo, :mistral)
      Application.put_env(:zaimu_tomo, :mistral, Keyword.put(mistral, :api_key, nil))

      fail_inserts!(
        "review_decisions",
        ReviewDecision.changeset_for_create(%{}),
        :extracted_content_id
      )

      capture_log(fn -> assert %{cancelled: 1} = Oban.drain_queue(queue: :documents) end)

      assert_received %{status: :failed, document_id: ^document_id}
      assert Repo.aggregate(ExtractedContent, :count) == 0
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :stuck}
    end
  end
end
