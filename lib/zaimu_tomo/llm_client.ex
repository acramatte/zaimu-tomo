defmodule ZaimuTomo.LLMClient do
  @moduledoc """
  Local hybrid client wrapping ReqLLM for multi-agent workflows.
  """
  require Logger

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.VerificationResult

  @backends [:ollama, :flm, :mistral]

  @type role :: :extractor | :verifier
  @type backend :: :ollama | :flm | :mistral
  @type workflow_config :: [
          extractor: backend() | String.t(),
          verifier: backend() | String.t(),
          currency_hint: String.t()
        ]
  @type backend_config :: [
          provider: atom(),
          base_url: String.t(),
          model: String.t(),
          api_key: String.t()
        ]
  @type extraction_payload :: ExtractedData.t() | map()
  @type validation_errors :: map()

  @doc """
  Extracts invoice JSON using the configured extraction backend.
  """
  @spec extract_invoice(String.t()) ::
          {:ok, ExtractedData.t()} | {:error, term()}
  def extract_invoice(markdown) do
    config = backend_config!(:extractor)
    model = req_llm_model!(config)
    opts = req_llm_opts(config)
    Logger.info("[LLM] Extracting invoice with #{backend_summary(:extractor, config)}")

    schema = [
      amount_to_pay_cents: [type: :pos_integer, required: true],
      invoice_date: [type: :string, required: true],
      invoice_number: [type: :string, required: false],
      currency: [type: :string, required: true],
      reason_for_payment: [type: :string, required: true],
      issuer: [type: :string, required: true]
    ]

    prompt = """
    Extract invoice fields from the OCR text.

    Rules:
    - Return only structured output matching the schema.
    - Never ask a question and never request clarification.
    - If multiple currencies appear, choose #{currency_hint()} when present.
    - If #{currency_hint()} is not present, choose the final amount charged or payable.
    - Put the chosen ISO 4217 currency code in currency.
    - Put the chosen amount in amount_to_pay_cents.
    - Put invoice_date in ISO 8601 YYYY-MM-DD format.
    - Use reason_for_payment for a short payment description.

    OCR Text:
    #{markdown}
    """

    case ReqLLM.generate_object(model, prompt, schema, opts) do
      {:ok, response} ->
        response
        |> ReqLLM.Response.object()
        |> parse_extracted_data(config)

      {:error, reason} ->
        Logger.error(
          "[LLM] Invoice extraction request failed with #{backend_summary(:extractor, config)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @spec parse_extracted_data(term(), backend_config()) ::
          {:ok, ExtractedData.t()} | {:error, term()}
  defp parse_extracted_data(data, config) when is_map(data) do
    case ExtractedData.changeset(data)
         |> Ecto.Changeset.apply_action(:parse) do
      {:ok, extracted_data} ->
        Logger.info(
          "[LLM] Invoice extraction completed with #{backend_summary(:extractor, config)}"
        )

        {:ok, extracted_data}

      {:error, changeset} ->
        errors = changeset_errors_to_string(changeset)

        Logger.error(
          "[LLM] Invoice extraction failed schema validation with #{backend_summary(:extractor, config)}: #{inspect(errors)}"
        )

        {:error, {:validation_failed, errors}}
    end
  end

  defp parse_extracted_data(_data, config) do
    Logger.error(
      "[LLM] Invoice extraction response missing structured object with #{backend_summary(:extractor, config)}"
    )

    {:error, :missing_structured_output}
  end

  @spec changeset_errors_to_string(Ecto.Changeset.t()) :: validation_errors()
  defp changeset_errors_to_string(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Verifies extraction against the markdown using the configured verifier backend.
  """
  @spec verify_extraction(String.t(), extraction_payload() | term()) ::
          {:ok, map()} | {:error, term()}
  def verify_extraction(markdown, json_data) do
    with {:ok, json_payload} <- normalize_json_data(json_data) do
      config = backend_config!(:verifier)
      model = req_llm_model!(config)
      opts = Keyword.merge(req_llm_opts(config), max_tokens: 300)
      Logger.info("[LLM] Verifying extraction with #{backend_summary(:verifier, config)}")

      schema = [
        status: [type: :string, required: true],
        reason: [type: :string, required: true],
        field_issues: [type: :string, required: false]
      ]

      prompt = """
      You are an extraction verification judge.
      Verify if the extracted JSON data is fully grounded in the source OCR markdown.

      Return structured output with:
      - status: one of verified, needs_review, rejected
      - reason: a concise explanation for the decision
      - field_issues: optional comma-separated field names that are ambiguous, contradicted, or unsupported

      Status rules:
      - verified: every extracted value is directly supported by the source OCR markdown.
      - needs_review: the extraction is plausible but the source OCR markdown is ambiguous or incomplete.
      - rejected: any extracted value is hallucinated, contradicted, or incorrect.

      Extracted JSON:
      #{Jason.encode!(json_payload)}

      Source OCR Markdown:
      #{markdown}
      """

      case ReqLLM.generate_object(model, prompt, schema, opts) do
        {:ok, response} ->
          raw_object = ReqLLM.Response.object(response)

          case verification_result(raw_object) do
            {:ok, %{"status" => "verified"} = verification} ->
              Logger.info(
                "[LLM] Extraction verification completed with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
              )

              {:ok, verification}

            {:ok, %{"status" => status} = verification} ->
              Logger.warning(
                "[LLM] Extraction verification returned #{status} with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
              )

              {:ok, verification}

            {:error, reason} ->
              raw_response = verifier_response_payload(response, raw_object)

              Logger.error(
                "[LLM] Extraction verification returned invalid structured output with #{backend_summary(:verifier, config)}: #{inspect(raw_response)} (#{inspect(reason)})"
              )

              {:ok, verification_failure_result(raw_response, reason)}
          end

        {:error, reason} ->
          Logger.error(
            "[LLM] Extraction verification request failed with #{backend_summary(:verifier, config)}: #{inspect(reason)}"
          )

          {:ok, verification_failure_result(%{"error" => inspect(reason)}, reason)}
      end
    end
  end

  @doc false
  @spec verification_result(map() | term()) :: {:ok, map()} | {:error, :verification_failed}
  def verification_result(%{} = data) do
    case VerificationResult.parse(data) do
      {:ok, result} -> {:ok, result}
      {:error, _changeset} -> {:error, :verification_failed}
    end
  end

  def verification_result(_data), do: {:error, :verification_failed}

  @doc false
  @spec verifier_response_payload(ReqLLM.Response.t(), term()) :: map()
  def verifier_response_payload(response, raw_object) do
    %{
      "raw_object" => raw_object,
      "text" => ReqLLM.Response.text(response),
      "tool_calls" => ReqLLM.Response.tool_calls(response),
      "finish_reason" => response.finish_reason,
      "provider_meta" => response.provider_meta,
      "usage" => response.usage
    }
  end

  @doc false
  @spec verification_failure_result(term(), term()) :: map()
  def verification_failure_result(raw_response, reason) do
    %{
      "status" => "verification_failed",
      "reason" => "Verifier did not return valid structured output.",
      "raw_response" => raw_response,
      "error" => inspect(reason)
    }
  end

  @doc false
  @spec backend_for(role()) :: backend()
  def backend_for(role) when role in [:extractor, :verifier] do
    workflow_config() |> Keyword.fetch!(role) |> normalize_backend()
  end

  @spec currency_hint() :: String.t()
  defp currency_hint do
    workflow_config()
    |> Keyword.get(:currency_hint, "CHF")
    |> String.upcase()
  end

  @spec workflow_config() :: workflow_config()
  defp workflow_config, do: Application.fetch_env!(:zaimu_tomo, :ai_workflow)

  @spec backend_config!(role()) :: backend_config()
  defp backend_config!(role) do
    backend = backend_for(role)
    Application.fetch_env!(:zaimu_tomo, backend)
  end

  @spec normalize_backend(backend() | String.t() | term()) :: backend()
  defp normalize_backend(backend) when backend in @backends, do: backend

  defp normalize_backend(backend) when is_binary(backend) do
    case String.downcase(backend) do
      "ollama" -> :ollama
      "flm" -> :flm
      "mistral" -> :mistral
      unknown -> raise ArgumentError, "unknown AI backend #{inspect(unknown)}"
    end
  end

  defp normalize_backend(backend) do
    raise ArgumentError, "unknown AI backend #{inspect(backend)}"
  end

  @spec req_llm_model!(backend_config()) :: LLMDB.Model.t()
  defp req_llm_model!(config) do
    ReqLLM.model!(%{
      provider: Keyword.fetch!(config, :provider),
      id: Keyword.fetch!(config, :model),
      base_url: Keyword.fetch!(config, :base_url)
    })
  end

  @spec req_llm_opts(backend_config()) :: keyword()
  defp req_llm_opts(config), do: [api_key: Keyword.fetch!(config, :api_key), temperature: 0.0]

  @spec backend_summary(role(), backend_config()) :: String.t()
  defp backend_summary(role, config) do
    "#{backend_for(role)}/#{Keyword.fetch!(config, :model)} at #{Keyword.fetch!(config, :base_url)}"
  end

  @spec normalize_json_data(extraction_payload() | term()) ::
          {:ok, map()} | {:error, :invalid_extraction_payload}
  defp normalize_json_data(%ExtractedData{} = extracted_data),
    do: {:ok, Map.from_struct(extracted_data)}

  defp normalize_json_data(data) when is_map(data), do: {:ok, data}
  defp normalize_json_data(_data), do: {:error, :invalid_extraction_payload}
end
