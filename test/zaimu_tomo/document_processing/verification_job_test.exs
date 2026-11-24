defmodule ZaimuTomo.DocumentProcessing.VerificationJobTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.AttemptOutcomes
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.Run
  alias ZaimuTomo.DocumentProcessing.VerificationJob

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]
  import ZaimuTomo.ReviewFixtures, only: [extracted_content_fixture: 3]

  # An OpenAI-compatible verifier whose answer each test sets with `answer/1`.
  defmodule VerifierStub do
    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      send(test_pid, :verifier_request)

      case :persistent_term.get({__MODULE__, :answer}) do
        {:status, status} ->
          Plug.Conn.send_resp(conn, status, "unavailable")

        {:content, content} ->
          response = %{
            id: "verifier-response",
            model: "verifier",
            choices: [
              %{
                index: 0,
                message: %{role: "assistant", content: content},
                finish_reason: "stop"
              }
            ],
            usage: %{prompt_tokens: 10, completion_tokens: 10, total_tokens: 20}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end
  end

  setup do
    for {key, value} <- [
          ai_workflow: [
            extractor: [backend: :ollama, model: "extractor"],
            verifier: [backend: :ollama, model: "verifier"]
          ],
          langfuse: [enabled: false, environment: "test"]
        ] do
      original = Application.get_env(:zaimu_tomo, key)
      Application.put_env(:zaimu_tomo, key, value)
      on_exit(fn -> Application.put_env(:zaimu_tomo, key, original) end)
    end

    original_ollama = Application.fetch_env!(:zaimu_tomo, :ollama)
    on_exit(fn -> Application.put_env(:zaimu_tomo, :ollama, original_ollama) end)

    server =
      start_supervised!({Bandit, plug: {VerifierStub, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:zaimu_tomo, :ollama,
      provider: :ollama,
      base_url: "http://127.0.0.1:#{port}/v1"
    )

    on_exit(fn -> :persistent_term.erase({VerifierStub, :answer}) end)

    scope = user_scope_fixture()
    document = document_fixture(scope, %{})

    content =
      extracted_content_fixture(document, scope.user, %{
        verification_status: "pending",
        raw_llm_response: %{"pages" => [%{"markdown" => "Invoice total: CHF 42.00"}]},
        analysis: %{"verification" => %{}}
      })

    DocumentProcessing.subscribe_events(scope)

    %{scope: scope, document: document, content: content}
  end

  defp answer(answer), do: :persistent_term.put({VerifierStub, :answer}, answer)

  defp verdict(status),
    do: {:content, Jason.encode!(%{status: status, reason: "Checked against the OCR text."})}

  defp perform(content, opts \\ []) do
    perform_job(
      VerificationJob,
      %{extracted_content_id: content.id, document_id: content.document_id},
      Keyword.merge([max_attempts: 4], opts)
    )
  end

  defp reload(content), do: ExtractedContentContext.get_by_id(content.id)

  describe "a verifier that answers" do
    test "records the verdict with the model and prompt version and tells the owner's pages",
         %{content: content, document: document} do
      answer(verdict("needs_review"))
      document_id = document.id

      assert :ok = perform(content, attempt: 2)

      content = reload(content)
      assert content.verification_status == "needs_review"
      verification = content.analysis["verification"]
      assert verification["reason"] == "Checked against the OCR text."
      assert verification["verifier_model"] == "verifier"
      assert is_integer(verification["prompt_version"])
      assert verification["attempts"] == 2
      refute Map.has_key?(verification, "status")

      assert_received %{status: "needs_review", document_id: ^document_id}
    end
  end

  describe "a verifier that fails" do
    test "a transient error before the final attempt leaves the row pending for a retry",
         %{content: content} do
      answer({:status, 503})

      capture_log(fn ->
        assert {:error, "verifier_request_failed:http_503"} = perform(content, attempt: 1)
      end)

      assert reload(content).verification_status == "pending"
      # One request per attempt: Oban owns the retries now.
      assert_received :verifier_request
      refute_received :verifier_request
    end

    test "a transient error on the final attempt records verification_failed once",
         %{content: content} do
      answer({:status, 503})

      capture_log(fn -> assert :ok = perform(content, attempt: 4) end)

      content = reload(content)
      assert content.verification_status == "verification_failed"
      assert content.analysis["verification"]["error"] == "verifier_request_failed:http_503"
      assert content.analysis["verification"]["attempts"] == 4
    end

    test "a permanent error records verification_failed on the first attempt",
         %{content: content} do
      answer({:status, 400})

      capture_log(fn -> assert :ok = perform(content, attempt: 1) end)

      content = reload(content)
      assert content.verification_status == "verification_failed"
      assert content.analysis["verification"]["attempts"] == 1
    end
  end

  describe "an unreadable verifier answer" do
    setup do
      answer({:content, "I could not decide."})
    end

    test "is retried the first time", %{content: content} do
      capture_log(fn -> assert {:error, "invalid_verifier_output"} = perform(content) end)
      assert reload(content).verification_status == "pending"
    end

    test "gives up the second time, even after another error in between",
         %{content: content} do
      # Attempt 1 was unreadable and attempt 2 a 503: the counter, not the
      # last error, decides that attempt 3 is the last unreadable answer.
      capture_log(fn ->
        assert :ok =
                 perform(content,
                   attempt: 3,
                   meta: %{
                     "invalid_outputs" => 1,
                     "last_error" => "verifier_request_failed:http_503"
                   }
                 )
      end)

      content = reload(content)
      assert content.verification_status == "verification_failed"
      assert content.analysis["verification"]["error"] == "invalid_verifier_output"
      assert content.analysis["verification"]["invalid_outputs"] == 2
    end
  end

  describe "a row that has its result" do
    test "is left alone and the job cancels", %{content: content} do
      {:ok, _} =
        ExtractedContentContext.record_verification(content.id, %{"status" => "verified"})

      answer(verdict("rejected"))

      assert {:cancel, :already_recorded} = perform(content)
      assert reload(content).verification_status == "verified"
      refute_received :verifier_request
    end
  end

  describe "record_verification/2" do
    test "a second write returns :already_recorded and keeps the first result",
         %{content: content} do
      assert {:ok, _} =
               ExtractedContentContext.record_verification(content.id, %{
                 "status" => "rejected",
                 "reason" => "first"
               })

      assert {:error, :already_recorded} =
               ExtractedContentContext.record_verification(content.id, %{
                 "status" => "verified",
                 "reason" => "second"
               })

      content = reload(content)
      assert content.verification_status == "rejected"
      assert content.analysis["verification"]["reason"] == "first"
    end

    test "raises on an unknown status instead of reporting it as already recorded",
         %{content: content} do
      assert_raise Ecto.InvalidChangesetError, fn ->
        ExtractedContentContext.record_verification(content.id, %{"status" => "maybe"})
      end

      assert reload(content).verification_status == "pending"
    end

    test "keeps the TypeSafe shadow written before it, and the shadow keeps the verdict",
         %{content: content} do
      shadow = %{"status" => "verified", "model" => "jev-latest"}

      {:ok, _} = ExtractedContentContext.put_typesafe_shadow(content.id, shadow)

      {:ok, _} =
        ExtractedContentContext.record_verification(content.id, %{
          "status" => "needs_review",
          "reason" => "check the date"
        })

      {:ok, _} = ExtractedContentContext.put_typesafe_shadow(content.id, shadow)

      verification = reload(content).analysis["verification"]
      assert verification["typesafe_shadow"] == shadow
      assert verification["reason"] == "check the date"
    end
  end

  describe "the database guard" do
    test "refuses a move out of an end state from any writer", %{content: content} do
      {:ok, _} =
        ExtractedContentContext.record_verification(content.id, %{"status" => "verified"})

      for status <- ["pending", "verification_failed"] do
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.query!("UPDATE extracted_content SET verification_status = $1 WHERE id = $2", [
              status,
              content.id
            ])
          end

        assert error.postgres.constraint == "extracted_content_verification_transition_check"
      end
    end

    test "refuses a success row inserted already verified", %{content: content} do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("""
          INSERT INTO extracted_content
            (document_id, user_id, status, extracted_data, verification_status, inserted_at, updated_at)
          SELECT document_id, user_id, 'success', extracted_data, 'verified', now(), now()
          FROM extracted_content WHERE id = #{content.id}
          """)
        end

      assert error.postgres.constraint == "extracted_content_verification_initial_status_check"
    end
  end

  describe "AttemptOutcomes for a verification job" do
    defp job(content, fields) do
      {:ok, job} =
        Oban.insert(
          VerificationJob.new(%{
            extracted_content_id: content.id,
            document_id: content.document_id
          })
        )

      {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: fields)
      Repo.reload!(job)
    end

    test "a failed attempt stores its code, counts an unreadable answer, and tells the pages",
         %{content: content, document: document} do
      job = job(content, state: "retryable", attempt: 1, attempted_at: DateTime.utc_now())
      document_id = document.id

      AttemptOutcomes.handle_event(
        [:oban, :job, :exception],
        %{},
        %{
          job: job,
          state: :failure,
          reason:
            Oban.PerformError.exception({VerificationJob, {:error, "invalid_verifier_output"}})
        },
        nil
      )

      assert %Oban.Job{meta: %{"last_error" => "invalid_verifier_output", "invalid_outputs" => 1}} =
               Repo.reload!(job)

      assert_received %{status: :attempt_failed, document_id: ^document_id}
      assert reload(content).verification_status == "pending"

      # The verification run is visible to the invoice page, but the document
      # stays out of processing: OCR readers never see verification jobs.
      assert %{^document_id => %Run{phase: :waiting_to_retry, attempt: 2, max_attempts: 4}} =
               DocumentProcessing.live_verification_runs([document_id])

      assert DocumentProcessing.live_runs([document_id]) == %{}
      assert DocumentProcessing.processing_states([document_id]) == %{document_id => :extracted}
    end

    test "a discarded final attempt records verification_failed with job_timeout",
         %{content: content} do
      job = job(content, state: "discarded", attempt: 4, attempted_at: DateTime.utc_now())

      capture_log(fn ->
        AttemptOutcomes.handle_event(
          [:oban, :job, :exception],
          %{},
          %{
            job: job,
            state: :discard,
            reason: Oban.TimeoutError.exception({VerificationJob, 150_000})
          },
          nil
        )
      end)

      content = reload(content)
      assert content.verification_status == "verification_failed"
      assert content.analysis["verification"]["error"] == "job_timeout"
      assert content.analysis["verification"]["attempts"] == 4
    end
  end
end
