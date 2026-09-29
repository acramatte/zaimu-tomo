defmodule ZaimuTomo.TypeSafeVerificationTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.Worker, as: PipelineWorker
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.TypeSafeVerification.Worker

  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures

  setup do
    original_typesafe = Application.fetch_env!(:zaimu_tomo, :typesafe)
    original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)

    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    Application.put_env(:zaimu_tomo, :typesafe,
      enabled: true,
      api_key: "test-api-key",
      model: "jev-latest",
      review_threshold: 0.7
    )

    on_exit(fn ->
      Application.put_env(:zaimu_tomo, :typesafe, original_typesafe)

      if original_langfuse do
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)

    :ok
  end

  describe "enqueue on success persistence" do
    test "enqueues a self-contained job whose args carry no markdown" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      assert {:ok, content} =
               PipelineWorker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."},
                 nil,
                 "CHF"
               )

      assert_enqueued(worker: Worker)
      assert [job] = all_enqueued(worker: Worker)
      assert job.args["extracted_content_id"] == content.id
      assert job.args["currency_hint"] == "CHF"

      assert Enum.sort(Map.keys(job.args)) ==
               ~w(currency_hint extracted_content_id traceparent)

      # Persisted first; the shadow is written by the job, not at enqueue time.
      refute Map.has_key?(content.analysis["verification"], "typesafe_shadow")
    end

    test "enqueues nothing when TypeSafe is disabled" do
      config = Application.fetch_env!(:zaimu_tomo, :typesafe)
      Application.put_env(:zaimu_tomo, :typesafe, Keyword.put(config, :enabled, false))

      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      assert {:ok, _content} =
               PipelineWorker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."},
                 nil,
                 "CHF"
               )

      refute_enqueued(worker: Worker)
    end

    test "a failed job insert commits the extraction with an enqueue_failed shadow" do
      # Test-only seam: replace the Oban job table's positive_max_attempts
      # check with an unsatisfiable one so the TypeSafe job insert
      # (max_attempts: 3) fails with a changeset error — Oban declares that
      # check constraint on its job changeset. No production seam is added;
      # the DDL rolls back with the sandbox transaction (same technique and
      # concurrency caveats as ocr_job_test's failure injection).
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT positive_max_attempts")

      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT positive_max_attempts CHECK (max_attempts > 100)"
      )

      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      log =
        capture_log(fn ->
          assert {:ok, content} =
                   PipelineWorker.persist_and_emit_success(
                     document,
                     extracted_data(),
                     %{"pages" => []},
                     %{"status" => "verified", "reason" => "All fields match."},
                     nil,
                     "CHF"
                   )

          # The extraction and its review decision are committed even though
          # the shadow job could not be enqueued (fail-open end to end).
          persisted = ExtractedContentContext.get_by_id(content.id)
          assert persisted.status == "success"

          assert %ReviewDecision{} =
                   Repo.get_by!(ReviewDecision, extracted_content_id: content.id)

          assert persisted.analysis["verification"]["typesafe_shadow"] == %{
                   "status" => "verification_failed",
                   "error" => "enqueue_failed"
                 }
        end)

      assert log =~ "class=enqueue_failed"
      assert all_enqueued(worker: Worker) == []

      # Restore the real check definition in-test (the sandbox rollback also
      # covers assertion failures above).
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT positive_max_attempts")

      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT positive_max_attempts CHECK (max_attempts > 0)"
      )
    end

    test "a superseded success write enqueues no TypeSafe job" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      {:ok, stale} = prior_extraction(document)
      {:ok, _newer} = prior_extraction(document)

      assert {:error, :already_processed} =
               PipelineWorker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."},
                 nil,
                 "CHF",
                 stale.id
               )

      # TypeSafe is enabled here: the lock/recheck guard runs before the
      # enqueue inside the transaction, so a superseded write must not reach it.
      assert all_enqueued(worker: Worker) == []
    end

    test "a success write for a deleted document enqueues no TypeSafe job" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)
      {:ok, _deleted} = Repo.delete(document)

      assert {:error, :document_deleted} =
               PipelineWorker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."},
                 nil,
                 "CHF"
               )

      assert all_enqueued(worker: Worker) == []
    end
  end

  describe "required-currency persistence contract" do
    test "only persist_and_emit_success/6 and /7 are exported" do
      arities =
        PipelineWorker.__info__(:functions)
        |> Enum.filter(&match?({:persist_and_emit_success, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort()

      # Default arguments would export smaller arities that let callers omit
      # verification, trace_id or the required currency hint; pin the export
      # surface so that omission cannot come back silently.
      assert arities == [6, 7]
    end

    test "an explicitly supplied nil currency raises and rolls back extraction, review and job writes" do
      # The currency hint is a required argument, never a silent skip: a nil
      # hint must fail the caller loudly before any shadow enqueue is reached,
      # and the transaction must roll back the content/review inserts that
      # already happened before the failure.
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      assert_raise FunctionClauseError, fn ->
        PipelineWorker.persist_and_emit_success(
          document,
          extracted_data(),
          %{"pages" => []},
          %{"status" => "verified", "reason" => "All fields match."},
          nil,
          nil
        )
      end

      assert Repo.aggregate(ExtractedContent, :count) == 0
      assert Repo.aggregate(ReviewDecision, :count) == 0
      assert all_enqueued(worker: Worker) == []
    end
  end

  defp prior_extraction(document) do
    ExtractedContentContext.create_extracted_content(%{
      document_id: document.id,
      user_id: document.user_id,
      extracted_data: %{},
      status: "failed",
      error_details: %{"type" => "prior", "message" => "already recorded"}
    })
  end

  defp extracted_data do
    %ExtractedData{
      amount_to_pay_cents: 4200,
      invoice_date: "2026-05-08",
      invoice_number: "INV-42",
      currency: "CHF",
      reason_for_payment: "Consulting services",
      issuer: "Example Ltd"
    }
  end
end
