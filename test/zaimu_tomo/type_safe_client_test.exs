defmodule ZaimuTomo.TypeSafeClientTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.TypeSafeClient

  @req_stub __MODULE__

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_config = Application.fetch_env!(:zaimu_tomo, :typesafe)

    Application.put_env(:zaimu_tomo, :typesafe,
      enabled: true,
      api_key: "test-api-key",
      base_url: "https://api.typesafe.test",
      model: "jev-latest",
      review_threshold: 0.7,
      req_http_options: [plug: {Req.Test, @req_stub}]
    )

    on_exit(fn -> Application.put_env(:zaimu_tomo, :typesafe, original_config) end)
  end

  test "evaluates structured invoice state" do
    Req.Test.expect(@req_stub, fn conn ->
      request = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert request["state"]["ocr_markdown"] == "Invoice INV-42 from Example Ltd for CHF 12.00"
      assert request["state"]["currency_hint"] == "CHF"
      assert request["state"]["extracted"]["amount_to_pay_cents"] == 1200
      assert request["state"]["extracted"]["invoice_number"] == "INV-42"

      assert Map.keys(request["questions"]) |> Enum.sort() ==
               ~w(amount_wrong currency_wrong invoice_date_wrong invoice_number_wrong issuer_wrong reason_for_payment_wrong)

      json_response(conn, answers_response(%{"invoice_date_wrong" => 0.2}))
    end)

    assert {:ok, shadow} =
             TypeSafeClient.verify_extraction(
               "Invoice INV-42 from Example Ltd for CHF 12.00",
               extracted_data(),
               "CHF"
             )

    assert shadow["status"] == "verified"
    assert shadow["max_error_probability"] == 0.2
    assert shadow["field_probabilities"]["invoice_date"] == 0.2
    assert shadow["model"] == "jev-latest"
    assert shadow["usage"].input_tokens == 120
    assert shadow["usage"].output_tokens == 6
    assert shadow["usage"].total_tokens == 126
  end

  test "flags fields whose error probability meets the review threshold" do
    Req.Test.expect(@req_stub, fn conn ->
      json_response(
        conn,
        answers_response(%{"amount_wrong" => 0.91, "issuer_wrong" => 0.75})
      )
    end)

    assert {:ok, shadow} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")

    assert shadow["status"] == "needs_review"
    assert shadow["field_issues"] == "amount_to_pay_cents,issuer"
    assert shadow["max_error_probability"] == 0.91
  end

  test "omits the speculative invoice-number judgment when no number was extracted" do
    Req.Test.expect(@req_stub, fn conn ->
      request = conn |> Req.Test.raw_body() |> Jason.decode!()
      refute Map.has_key?(request["questions"], "invoice_number_wrong")

      response =
        answers_response()
        |> update_in(["answers"], &Map.delete(&1, "invoice_number_wrong"))

      json_response(conn, response)
    end)

    extracted = %{extracted_data() | invoice_number: nil}

    assert {:ok, %{"status" => "verified"}} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted, "CHF")
  end

  test "rejects review thresholds outside the probability range" do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)
    Application.put_env(:zaimu_tomo, :typesafe, Keyword.put(config, :review_threshold, 1.1))

    assert {:error, :invalid_configuration} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  test "does not flag an omitted optional field at the zero threshold" do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)
    Application.put_env(:zaimu_tomo, :typesafe, Keyword.put(config, :review_threshold, 0.0))

    Req.Test.expect(@req_stub, fn conn ->
      response =
        answers_response(%{
          "amount_wrong" => 0.0,
          "invoice_date_wrong" => 0.0,
          "currency_wrong" => 0.0,
          "reason_for_payment_wrong" => 0.0,
          "issuer_wrong" => 0.0
        })
        |> update_in(["answers"], &Map.delete(&1, "invoice_number_wrong"))

      json_response(conn, response)
    end)

    extracted = %{extracted_data() | invoice_number: nil}

    assert {:ok, shadow} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted, "CHF")

    assert shadow["field_issues"] ==
             "amount_to_pay_cents,invoice_date,currency,reason_for_payment,issuer"
  end

  test "returns a sanitized error for malformed API answers" do
    Req.Test.expect(@req_stub, fn conn ->
      json_response(conn, %{"model" => "jev-latest", "answers" => %{}})
    end)

    assert {:error, :invalid_response} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  test "classifies HTTP failures without retaining provider payloads" do
    put_evaluator(fn _model, _state, _questions, _options ->
      {:error,
       struct(ReqLLM.Error.API.Request,
         cause: struct(ReqLLM.Error.API.Response, status: 429),
         status: 429,
         reason: "response included sensitive details",
         response_body: %{"secret" => "provider payload"}
       )}
    end)

    assert {:error, {:http, 429}} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")

    put_evaluator(fn _model, _state, _questions, _options ->
      {:error,
       struct(ReqLLM.Error.API.Request,
         cause: struct(ReqLLM.Error.API.Response, status: 401),
         reason: "response included sensitive details",
         response_body: %{"secret" => "provider payload"}
       )}
    end)

    assert {:error, {:http, 401}} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  test "classifies request timeouts separately from other transport failures" do
    put_evaluator(fn _model, _state, _questions, _options ->
      {:error, struct(ReqLLM.Error.API.Timeout, kind: :total, timeout: 250)}
    end)

    assert {:error, :timeout} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")

    put_evaluator(fn _model, _state, _questions, _options ->
      {:error,
       struct(ReqLLM.Error.API.Request,
         cause: %Req.TransportError{reason: :timeout},
         reason: "request timed out"
       )}
    end)

    assert {:error, :timeout} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")

    put_evaluator(fn _model, _state, _questions, _options ->
      {:error,
       struct(ReqLLM.Error.API.Request,
         cause: %Req.TransportError{reason: :econnrefused},
         reason: "connection refused"
       )}
    end)

    assert {:error, :transport} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  test "classifies malformed evaluator returns as invalid responses" do
    put_evaluator(fn _model, _state, _questions, _options -> :malformed end)

    assert {:error, :invalid_response} =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  test "does not call the API when shadow verification is disabled" do
    Application.put_env(:zaimu_tomo, :typesafe, enabled: false)

    assert :disabled =
             TypeSafeClient.verify_extraction("OCR markdown", extracted_data(), "CHF")
  end

  defp put_evaluator(evaluator) do
    config = Application.fetch_env!(:zaimu_tomo, :typesafe)
    Application.put_env(:zaimu_tomo, :typesafe, Keyword.put(config, :evaluator, evaluator))
  end

  defp extracted_data do
    %ExtractedData{
      amount_to_pay_cents: 1200,
      invoice_date: "2026-01-01",
      invoice_number: "INV-42",
      currency: "CHF",
      reason_for_payment: "Consulting services",
      issuer: "Example Ltd"
    }
  end

  defp answers_response(overrides \\ %{}) do
    probabilities =
      %{
        "amount_wrong" => 0.1,
        "invoice_date_wrong" => 0.1,
        "invoice_number_wrong" => 0.1,
        "currency_wrong" => 0.1,
        "reason_for_payment_wrong" => 0.1,
        "issuer_wrong" => 0.1
      }
      |> Map.merge(overrides)

    %{
      "model" => "jev-latest",
      "answers" =>
        Map.new(probabilities, fn {id, probability} ->
          {id, %{"type" => "noul", "noul" => probability}}
        end),
      "usage" => %{"input_tokens" => 120, "output_tokens" => 6}
    }
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
