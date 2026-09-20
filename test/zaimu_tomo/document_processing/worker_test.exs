defmodule ZaimuTomo.DocumentProcessing.WorkerTest do
  use ZaimuTomo.DataCase, async: false

  alias ReqLLM.Response
  alias ZaimuTomo.DocumentProcessing.Worker
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

  describe "process/1" do
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

      assert {:ok, %{status: "failed"}} =
               Worker.process(%{document: document, currency_hint: "CHF"})

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

    test "persists first and forwards the currency hint to asynchronous TypeSafe verification" do
      original_typesafe = Application.fetch_env!(:zaimu_tomo, :typesafe)
      test_pid = self()

      Application.put_env(:zaimu_tomo, :typesafe,
        enabled: true,
        api_key: "test-api-key",
        model: "jev-latest",
        review_threshold: 0.7,
        total_timeout: 250,
        max_retries: 0,
        evaluator: fn _model, state, questions, _options ->
          send(test_pid, {:typesafe_started, state, self()})

          receive do
            :release ->
              answers =
                Map.new(questions, fn {id, _question} ->
                  {id, %{"type" => "boolean", "probability" => 0.1}}
                end)

              {:ok,
               %Response{
                 id: "eval-test",
                 model: "jev-latest",
                 context: ReqLLM.Context.new(),
                 object: answers,
                 usage: %{}
               }}
          end
        end
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
                 %{
                   markdown: "Invoice INV-42 total: CHF 42.00",
                   currency_hint: "CHF",
                   trace_context: OpenTelemetry.Ctx.get_current()
                 }
               )

      refute Map.has_key?(content.analysis["verification"], "typesafe_shadow")
      assert_receive {:typesafe_started, state, worker_pid}
      assert state["currency_hint"] == "CHF"

      send(worker_pid, :release)

      assert eventually(fn ->
               updated =
                 ZaimuTomo.DocumentProcessing.ExtractedContentContext.get_by_id(content.id)

               updated.analysis["verification"]["typesafe_shadow"]["status"] == "verified"
             end)
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
                 {:llm_request_failed, String.duplicate("connection refused ", 100)}
               )

      review_decision = Repo.get_by!(ReviewDecision, extracted_content_id: content.id)

      assert review_decision.review_notes ==
               "Automatically marked as failed: llm_request_failed"
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

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
