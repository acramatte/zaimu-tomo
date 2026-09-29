defmodule ZaimuTomo.TypeSafeVerificationTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.Worker, as: PipelineWorker
  alias ZaimuTomo.TypeSafeVerification.Worker

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

    test "enqueues nothing when no currency hint is forwarded" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      assert {:ok, _content} =
               PipelineWorker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."}
               )

      refute_enqueued(worker: Worker)
    end
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
