defmodule ZaimuTomo.DocumentProcessing.AttemptOutcomesTest do
  use ZaimuTomo.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ZaimuTomo.Activity
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.AttemptOutcomes
  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.DocumentProcessing.Run
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

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
end
