defmodule ZaimuTomo.TypeSafeClient do
  @moduledoc """
  Shadow verification of extracted invoice fields with TypeSafe System One.

  The generative verifier remains authoritative while this client records Jev's
  independent per-field error probabilities for evaluation.
  """

  alias ZaimuTomo.DocumentProcessing.ExtractedData

  @questions %{
    "amount_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.amount_to_pay_cents` wrong or unsupported by `ocr_markdown`?",
      criteria: %{
        true: "The amount payable in cents conflicts with, or cannot be found in, the document.",
        false:
          "The amount payable is supported by the document, allowing for ordinary currency formatting."
      }
    },
    "invoice_date_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.invoice_date` wrong or unsupported by `ocr_markdown`?",
      criteria: %{
        true: "The extracted invoice date conflicts with, or cannot be found in, the document.",
        false:
          "The extracted invoice date is supported by the document, allowing for equivalent date formats."
      }
    },
    "currency_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.currency` wrong given `ocr_markdown` and `currency_hint`?",
      criteria: %{
        true:
          "The extracted currency conflicts with the payable amount or incorrectly resolves an ambiguous currency instead of using the hint.",
        false:
          "The currency is supported by the document, using the hint only to resolve genuine ambiguity."
      }
    },
    "reason_for_payment_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.reason_for_payment` wrong or unsupported by `ocr_markdown`?",
      criteria: %{
        true:
          "The payment reason misstates the billed goods or services, or lacks support in the document.",
        false: "The payment reason faithfully summarizes goods or services shown in the document."
      }
    },
    "issuer_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.issuer` wrong or unsupported by `ocr_markdown`?",
      criteria: %{
        true: "The issuer conflicts with, or cannot be identified from, the document.",
        false: "The issuer is supported by the document."
      }
    },
    "invoice_number_wrong" => %{
      type: :boolean,
      instructions: "Is `extracted.invoice_number` wrong or unsupported by `ocr_markdown`?",
      criteria: %{
        true: "The invoice number conflicts with, or cannot be found in, the document.",
        false: "The invoice number is supported by the document."
      }
    }
  }

  @field_by_question %{
    "amount_wrong" => "amount_to_pay_cents",
    "invoice_date_wrong" => "invoice_date",
    "currency_wrong" => "currency",
    "reason_for_payment_wrong" => "reason_for_payment",
    "issuer_wrong" => "issuer",
    "invoice_number_wrong" => "invoice_number"
  }

  @field_order [
    "amount_to_pay_cents",
    "invoice_date",
    "currency",
    "reason_for_payment",
    "issuer",
    "invoice_number"
  ]

  @type extraction_payload :: ExtractedData.t() | map()
  @type shadow_result :: %{String.t() => term()}

  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @spec verify_extraction(String.t(), extraction_payload(), String.t()) ::
          {:ok, shadow_result()} | {:error, term()} | :disabled
  def verify_extraction(markdown, extracted_data, currency_hint)
      when is_binary(markdown) and is_binary(currency_hint) do
    config = config()

    if enabled?() do
      with {:ok, api_key} <- api_key(config),
           {:ok, threshold} <- review_threshold(config),
           {:ok, extracted} <- normalize_extracted_data(extracted_data),
           questions = questions(extracted),
           {:ok, response} <-
             request(state(markdown, extracted, currency_hint), questions, api_key, config),
           {:ok, probabilities} <- parse_probabilities(response, questions) do
        {:ok, compose_result(response, probabilities, threshold)}
      end
    else
      :disabled
    end
  end

  def verify_extraction(_markdown, _extracted_data, _currency_hint),
    do: {:error, :invalid_input}

  defp state(markdown, extracted, currency_hint) do
    %{
      "ocr_markdown" => markdown,
      "extracted" => extracted,
      "currency_hint" => currency_hint
    }
  end

  defp questions(%{"invoice_number" => value}) when value in [nil, ""],
    do: Map.delete(@questions, "invoice_number_wrong")

  defp questions(_extracted), do: @questions

  defp request(state, questions, api_key, config) do
    options = [
      api_key: api_key,
      base_url: Keyword.get(config, :base_url, "https://api.typesafe.ai"),
      receive_timeout: Keyword.get(config, :receive_timeout, 30_000),
      total_timeout: Keyword.get(config, :total_timeout, 10_000),
      max_retries: Keyword.get(config, :max_retries, 0),
      req_http_options: Keyword.get(config, :req_http_options, [])
    ]

    evaluator = Keyword.get(config, :evaluator, &ReqLLM.evaluate/4)

    case evaluator.(model_spec(config), state, questions, options) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, classify_request_error(reason)}

      _invalid_response ->
        {:error, :invalid_response}
    end
  end

  defp classify_request_error(%ReqLLM.Error.API.Timeout{}), do: :timeout

  defp classify_request_error(%ReqLLM.Error.API.Request{status: status})
       when is_integer(status) and status not in 200..299,
       do: {:http, status}

  defp classify_request_error(%ReqLLM.Error.API.Request{
         cause: %ReqLLM.Error.API.Response{status: status}
       })
       when is_integer(status) and status not in 200..299,
       do: {:http, status}

  defp classify_request_error(%ReqLLM.Error.API.Request{
         cause: %ReqLLM.Error.API.Response{status: status}
       })
       when status in 200..299,
       do: :invalid_response

  defp classify_request_error(%ReqLLM.Error.API.Request{cause: %{reason: :timeout}}),
    do: :timeout

  defp classify_request_error(%ReqLLM.Error.API.Request{
         cause: %{__struct__: module, reason: _reason}
       })
       when module in [Req.TransportError, Finch.TransportError, Mint.TransportError],
       do: :transport

  defp classify_request_error(%ReqLLM.Error.API.Response{}), do: :invalid_response
  defp classify_request_error(_reason), do: :request_failed

  defp parse_probabilities(%ReqLLM.Response{object: answers}, questions) when is_map(answers) do
    questions
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}}, fn id, {:ok, probabilities} ->
      case answers[id] do
        %{"type" => "boolean", "probability" => probability}
        when is_number(probability) and probability >= 0 and probability <= 1 ->
          field = field_for_question(id)
          {:cont, {:ok, Map.put(probabilities, field, probability / 1)}}

        _other ->
          {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp parse_probabilities(_response, _questions), do: {:error, :invalid_response}

  defp compose_result(response, probabilities, threshold) do
    issues =
      @field_order
      |> Enum.filter(fn field ->
        case Map.fetch(probabilities, field) do
          {:ok, probability} -> probability >= threshold
          :error -> false
        end
      end)

    %{
      "status" => if(issues == [], do: "verified", else: "needs_review"),
      "field_probabilities" => probabilities,
      "max_error_probability" => probabilities |> Map.values() |> Enum.max(),
      "review_threshold" => threshold,
      "model" => response.model,
      "usage" => response.usage
    }
    |> maybe_put_field_issues(issues)
  end

  defp maybe_put_field_issues(result, []), do: result

  defp maybe_put_field_issues(result, issues),
    do: Map.put(result, "field_issues", Enum.join(issues, ","))

  defp normalize_extracted_data(%ExtractedData{} = extracted_data) do
    {:ok, extracted_data |> Map.from_struct() |> normalize_extracted_map()}
  end

  defp normalize_extracted_data(extracted_data) when is_map(extracted_data) do
    changeset = ExtractedData.embedded_changeset(%ExtractedData{}, extracted_data)

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, validated_data} -> normalize_extracted_data(validated_data)
      {:error, _changeset} -> {:error, :invalid_extraction_payload}
    end
  end

  defp normalize_extracted_data(_extracted_data), do: {:error, :invalid_extraction_payload}

  defp normalize_extracted_map(map) do
    fields = Enum.map(ExtractedData.fields(), &Atom.to_string/1)
    map |> stringify_keys() |> Map.take(fields)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp field_for_question(question_id), do: Map.fetch!(@field_by_question, question_id)

  defp model_spec(config) do
    model = Keyword.get(config, :model, "jev-latest")

    if String.starts_with?(model, "typesafe:"), do: model, else: "typesafe:#{model}"
  end

  defp api_key(config) do
    case Keyword.get(config, :api_key) do
      api_key when is_binary(api_key) and byte_size(api_key) > 0 -> {:ok, api_key}
      _api_key -> {:error, :missing_api_key}
    end
  end

  defp review_threshold(config) do
    case Keyword.get(config, :review_threshold, 0.7) do
      threshold when is_number(threshold) and threshold >= 0 and threshold <= 1 ->
        {:ok, threshold / 1}

      _threshold ->
        {:error, :invalid_configuration}
    end
  end

  defp config, do: Application.fetch_env!(:zaimu_tomo, :typesafe)
end
