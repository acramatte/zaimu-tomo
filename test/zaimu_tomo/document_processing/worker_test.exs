defmodule ZaimuTomo.DocumentProcessing.WorkerTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ZaimuTomo.DocumentProcessing.Worker
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Repo
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import Bitwise, only: [band: 2]

  defmodule TemporaryFileStorage do
    @behaviour ZaimuTomo.Storage.Adapter

    @impl true
    def put_object(key, _body, _config), do: {:ok, key}

    @impl true
    def get_object(_key, destination, config) do
      send(
        Keyword.fetch!(config, :test_pid),
        {:document_downloaded, destination, File.stat!(destination),
         File.stat!(Path.dirname(destination))}
      )

      File.write(destination, "invoice bytes")
      {:ok, destination}
    end

    @impl true
    def delete_object(_key, _config), do: :ok

    @impl true
    def read_object(_key, _config), do: {:error, :not_found}

    @impl true
    def head_object(_key, _config), do: :ok
  end

  describe "run/1" do
    test "downloads the object to a private temporary file and removes it after OCR" do
      storage_config = Application.fetch_env!(:zaimu_tomo, :storage)
      mistral_config = Application.fetch_env!(:zaimu_tomo, :mistral)
      langfuse_config = Application.get_env(:zaimu_tomo, :langfuse)

      Application.put_env(:zaimu_tomo, :storage,
        adapter: TemporaryFileStorage,
        test_pid: self()
      )

      Application.put_env(:zaimu_tomo, :mistral, Keyword.put(mistral_config, :api_key, nil))
      Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

      on_exit(fn ->
        Application.put_env(:zaimu_tomo, :storage, storage_config)
        Application.put_env(:zaimu_tomo, :mistral, mistral_config)

        if langfuse_config do
          Application.put_env(:zaimu_tomo, :langfuse, langfuse_config)
        else
          Application.delete_env(:zaimu_tomo, :langfuse)
        end
      end)

      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{object_key: "documents/invoice.pdf"})

      assert {:error, {:ocr_upload_failed, "Missing Mistral API key"}} =
               Worker.run(%{
                 document: document,
                 currency_hint: "CHF",
                 supersedes_extraction_id: nil
               })

      assert_receive {:document_downloaded, temporary_path, file_stat, directory_stat}
      assert band(file_stat.mode, 0o777) == 0o600
      assert band(directory_stat.mode, 0o777) == 0o700
      refute File.exists?(temporary_path)
    end
  end

  describe "persist_and_emit_success/3" do
    test "includes user_id from document in extracted content and stores raw response" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      raw_llm_response = %{"amount_to_pay_cents" => 1000, "issuer" => "Test Issuer"}

      {:ok, content} = Worker.persist_and_emit_success(document, extracted_data, raw_llm_response)

      assert content.user_id == user.id
      assert content.document_id == document.id
      assert content.status == "success"
      assert content.raw_llm_response == raw_llm_response
      assert content.analysis["verification"]["status"] == "not_run"
      assert content.trace_id == nil
    end

    test "persists the Langfuse trace id when provided" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      {:ok, content} =
        Worker.persist_and_emit_success(
          document,
          extracted_data,
          %{},
          %{"status" => "verified"},
          "abc123def456abc123def456abc123def4"
        )

      assert content.trace_id == "abc123def456abc123def456abc123def4"
    end

    test "stores verifier analysis when provided" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      }

      raw_llm_response = %{"pages" => []}
      verification = %{"status" => "needs_review", "raw_response" => "NEEDS_REVIEW"}

      {:ok, content} =
        Worker.persist_and_emit_success(document, extracted_data, raw_llm_response, verification)

      assert content.status == "success"
      assert content.analysis["verification"] == verification
    end

    test "persists first and enqueues the TypeSafe shadow job with the currency hint" do
      original_typesafe = Application.fetch_env!(:zaimu_tomo, :typesafe)

      Application.put_env(:zaimu_tomo, :typesafe,
        enabled: true,
        api_key: "test-api-key",
        model: "jev-latest",
        review_threshold: 0.7
      )

      on_exit(fn -> Application.put_env(:zaimu_tomo, :typesafe, original_typesafe) end)

      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      extracted_data = %ExtractedData{
        amount_to_pay_cents: 4200,
        invoice_date: "2026-05-08",
        invoice_number: "INV-42",
        currency: "CHF",
        reason_for_payment: "Consulting services",
        issuer: "Example Ltd"
      }

      assert {:ok, content} =
               Worker.persist_and_emit_success(
                 document,
                 extracted_data,
                 %{"pages" => []},
                 %{"status" => "verified", "reason" => "All fields match."},
                 nil,
                 "CHF"
               )

      # Persisted first; the shadow is written when the job runs, not at
      # enqueue time (jobs are manual in tests).
      refute Map.has_key?(content.analysis["verification"], "typesafe_shadow")

      assert_enqueued(
        worker: ZaimuTomo.TypeSafeVerification.Worker,
        args: %{currency_hint: "CHF"}
      )
    end
  end

  describe "persist_and_emit_failure/2" do
    test "persists failed OCR attempts without extracted invoice data" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      assert {:ok, content} =
               Worker.persist_and_emit_failure(
                 document,
                 {:ocr_upload_failed, "Missing Mistral API key"}
               )

      assert content.user_id == user.id
      assert content.document_id == document.id
      assert content.status == "failed"
      assert content.extracted_data.amount_to_pay_cents == nil
      assert content.extracted_data.invoice_date == nil
      assert content.error_details["type"] == "ocr_upload_failed"
      assert content.error_details["message"] == "Missing Mistral API key"
    end

    test "persists a failed review when the error reason exceeds the review notes limit" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})

      assert {:ok, content} =
               Worker.persist_and_emit_failure(
                 document,
                 {:llm_request_failed,
                  %{status: nil, reason: String.duplicate("connection refused ", 100)}}
               )

      review_decision = Repo.get_by!(ReviewDecision, extracted_content_id: content.id)

      assert review_decision.review_notes ==
               "Automatically marked as failed: llm_request_failed"
    end
  end

  describe "terminal-write serialization" do
    test "a stale expected extraction id makes the success persist write no second row" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})
      {:ok, stale} = insert_failed_extraction(document)
      {:ok, _newer} = insert_failed_extraction(document)

      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")

      assert {:error, :already_processed} =
               Worker.persist_and_emit_success(
                 document,
                 extracted_data(),
                 %{},
                 %{"status" => "not_run"},
                 nil,
                 nil,
                 stale.id
               )

      assert Repo.aggregate(ExtractedContent, :count) == 2
      refute_received %{status: :completed}
    end

    test "a stale expected extraction id makes the failure persist write no second row" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})
      {:ok, stale} = insert_failed_extraction(document)
      {:ok, _newer} = insert_failed_extraction(document)

      Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")

      assert {:error, :already_processed} =
               Worker.persist_and_emit_failure(document, {:ocr_upload_failed, :enoent}, stale.id)

      assert Repo.aggregate(ExtractedContent, :count) == 2
      refute_received %{status: :failed}
    end

    test "the expected latest extraction id lets the terminal write proceed" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})
      {:ok, expected} = insert_failed_extraction(document)

      assert {:ok, content} =
               Worker.persist_and_emit_failure(
                 document,
                 {:ocr_upload_failed, :enoent},
                 expected.id
               )

      assert content.status == "failed"
      assert Repo.aggregate(ExtractedContent, :count) == 2
    end

    test "a deleted document makes the terminal write a :document_deleted no-op" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope, %{})
      {:ok, _} = Repo.delete(document)

      assert {:error, :document_deleted} =
               Worker.persist_and_emit_failure(document, {:ocr_upload_failed, :enoent}, nil)

      assert Repo.aggregate(ExtractedContent, :count) == 0
    end
  end

  defp insert_failed_extraction(document) do
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
      amount_to_pay_cents: 1000,
      invoice_date: "2024-01-15",
      invoice_number: "INV-001",
      currency: "USD",
      reason_for_payment: "Test payment",
      issuer: "Test Issuer"
    }
  end

  defp document_fixture(scope, attrs) do
    attrs =
      Enum.into(attrs, %{
        filename: "some filename",
        object_key: "documents/some-file.pdf",
        user_id: scope.user.id
      })

    Repo.insert!(struct!(Document, attrs))
  end
end
