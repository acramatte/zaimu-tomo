defmodule ZaimuTomo.TypeSafeVerificationWorkerTest do
  use ZaimuTomo.DataCase, async: false

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
    test_pid = self()

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

    on_exit(fn -> Application.put_env(:zaimu_tomo, :typesafe, original_config) end)
  end

  test "persists the shadow result with the forwarded currency hint" do
    user = user_fixture()
    scope = user_scope_fixture(user)
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{"status" => "verified", "reason" => "All fields match."}
        }
      })

    assert :ok =
             Worker.perform(%{
               extracted_content_id: extracted_content.id,
               markdown: "Invoice total: CHF 42.00",
               extracted_data: extracted_content.extracted_data,
               currency_hint: "CHF"
             })

    assert_received {:evaluation, "typesafe:jev-latest", state, options}
    assert state["currency_hint"] == "CHF"
    assert options[:total_timeout] == 250
    assert options[:max_retries] == 0

    updated = ExtractedContentContext.get_by_id(extracted_content.id)
    assert updated.analysis["verification"]["status"] == "verified"
    assert updated.analysis["verification"]["typesafe_shadow"]["status"] == "verified"
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

    user = user_fixture()
    scope = user_scope_fixture(user)
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{"status" => "verified", "reason" => "All fields match."}
        }
      })

    log =
      capture_log(fn ->
        assert :ok =
                 Worker.perform(%{
                   extracted_content_id: extracted_content.id,
                   markdown: "OCR markdown must not appear in logs",
                   extracted_data: extracted_content.extracted_data,
                   currency_hint: "CHF"
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

  test "logs when a classified failure cannot be persisted" do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)

    Application.put_env(
      :zaimu_tomo,
      :typesafe,
      Keyword.put(config, :evaluator, fn _model, _state, _questions, _options ->
        {:error, struct(ReqLLM.Error.API.Timeout, kind: :total, timeout: 250)}
      end)
    )

    log =
      capture_log(fn ->
        assert :ok =
                 Worker.perform(%{
                   extracted_content_id: -1,
                   markdown: "private OCR",
                   extracted_data: %{
                     amount_to_pay_cents: 1200,
                     invoice_date: "2026-01-01",
                     currency: "CHF",
                     reason_for_payment: "Consulting services",
                     issuer: "Example Ltd"
                   },
                   currency_hint: "CHF"
                 })
      end)

    assert log =~ "Shadow verification failed class=timeout"
    assert log =~ "Shadow verification persistence failed class=extracted_content_not_found"
    refute log =~ "private OCR"
  end
end
