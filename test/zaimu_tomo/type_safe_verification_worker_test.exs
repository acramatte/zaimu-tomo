defmodule ZaimuTomo.TypeSafeVerificationWorkerTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  alias ReqLLM.Response
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.TypeSafeVerification.Worker

  defmodule SensitiveEvaluator do
    def evaluate(:never, _state, _questions, _options), do: :ok
  end

  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  setup do
    original_config = Application.fetch_env!(:zaimu_tomo, :typesafe)
    original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)
    test_pid = self()

    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    Application.put_env(:zaimu_tomo, :typesafe,
      enabled: true,
      api_key: "test-api-key",
      model: "jev-latest",
      review_threshold: 0.7,
      receive_timeout: 1_000,
      total_timeout: 250,
      max_retries: 0,
      evaluator: fn model, state, questions, options ->
        send(test_pid, {:evaluation, model, state, options})

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
    )

    on_exit(fn ->
      Application.put_env(:zaimu_tomo, :typesafe, original_config)

      if original_langfuse do
        Application.put_env(:zaimu_tomo, :langfuse, original_langfuse)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)
  end

  test "re-derives markdown from the row and persists the shadow result" do
    extracted_content = extracted_content_fixture_with_markdown()

    assert :ok =
             perform_job(Worker, %{
               extracted_content_id: extracted_content.id,
               currency_hint: "CHF",
               traceparent: nil
             })

    assert_received {:evaluation, "typesafe:jev-latest", state, options}
    assert state["ocr_markdown"] == "Invoice total: CHF 42.00"
    assert state["currency_hint"] == "CHF"
    assert options[:total_timeout] == 250
    assert options[:max_retries] == 0

    updated = ExtractedContentContext.get_by_id(extracted_content.id)
    assert updated.analysis["verification"]["status"] == "verified"
    assert updated.analysis["verification"]["typesafe_shadow"]["status"] == "verified"
  end

  test "a client failure writes a verification_failed shadow and returns :ok" do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)

    Application.put_env(
      :zaimu_tomo,
      :typesafe,
      Keyword.put(config, :evaluator, fn _model, _state, _questions, _options ->
        {:error, struct(ReqLLM.Error.API.Timeout, kind: :total, timeout: 250)}
      end)
    )

    extracted_content = extracted_content_fixture_with_markdown()

    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(Worker, %{
                   extracted_content_id: extracted_content.id,
                   currency_hint: "CHF",
                   traceparent: nil
                 })
      end)

    assert log =~ "Shadow verification failed class=timeout"

    updated = ExtractedContentContext.get_by_id(extracted_content.id)

    assert updated.analysis["verification"]["typesafe_shadow"] == %{
             "status" => "verification_failed",
             "error" => "timeout"
           }
  end

  test "an unexpected raw body writes a markdown_unavailable shadow" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        raw_llm_response: %{"unexpected" => true},
        analysis: %{
          "verification" => %{"status" => "verified", "reason" => "All fields match."}
        }
      })

    assert :ok =
             perform_job(Worker, %{
               extracted_content_id: extracted_content.id,
               currency_hint: "CHF",
               traceparent: nil
             })

    refute_received {:evaluation, _model, _state, _options}

    updated = ExtractedContentContext.get_by_id(extracted_content.id)

    assert updated.analysis["verification"]["typesafe_shadow"] == %{
             "status" => "verification_failed",
             "error" => "markdown_unavailable"
           }
  end

  test "a missing content row cancels the job" do
    assert {:cancel, :extracted_content_deleted} =
             perform_job(Worker, %{
               extracted_content_id: -1,
               currency_hint: "CHF",
               traceparent: nil
             })

    refute_received {:evaluation, _model, _state, _options}
  end

  test "persists unexpected exceptions and logs a sanitized stacktrace" do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)

    Application.put_env(
      :zaimu_tomo,
      :typesafe,
      Keyword.put(config, :evaluator, fn model, state, questions, options ->
        SensitiveEvaluator.evaluate(model, state, questions, options)
      end)
    )

    extracted_content =
      extracted_content_fixture_with_markdown("OCR markdown must not appear in logs")

    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(Worker, %{
                   extracted_content_id: extracted_content.id,
                   currency_hint: "CHF",
                   traceparent: nil
                 })
      end)

    assert log =~ "class=exception:Elixir.FunctionClauseError"
    assert log =~ "SensitiveEvaluator.evaluate/4"
    refute log =~ "OCR markdown must not appear in logs"
    refute log =~ "test-api-key"

    updated = ExtractedContentContext.get_by_id(extracted_content.id)

    assert updated.analysis["verification"]["typesafe_shadow"] == %{
             "status" => "verification_failed",
             "error" => "exception:Elixir.FunctionClauseError"
           }
  end

  defp extracted_content_fixture_with_markdown(markdown \\ "Invoice total: CHF 42.00") do
    user = user_fixture()
    scope = user_scope_fixture(user)
    document = document_fixture(scope)

    extracted_content_fixture(document, user, %{
      raw_llm_response: %{"pages" => [%{"markdown" => markdown}]},
      analysis: %{
        "verification" => %{"status" => "verified", "reason" => "All fields match."}
      }
    })
  end
end
