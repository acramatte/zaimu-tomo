defmodule ZaimuTomo.LLMClient do
  @moduledoc """
  Local hybrid client wrapping ReqLLM for multi-agent workflows.
  """
  require Logger

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.VerificationResult
  alias ZaimuTomo.Langfuse

  @backends [:ollama, :flm, :mistral, :nousresearch]

  @type role :: :extractor | :verifier
  @type backend :: :ollama | :flm | :mistral | :nousresearch
  @type role_config :: [backend: backend() | String.t(), model: String.t()]
  @type workflow_config :: [extractor: role_config(), verifier: role_config()]
  @type backend_config :: [provider: atom(), base_url: String.t(), api_key: String.t() | nil]
  @type resolved_backend_config :: [
          provider: atom(),
          base_url: String.t(),
          model: String.t(),
          api_key: String.t()
        ]
  @type extraction_payload :: ExtractedData.t() | map()
  @type validation_errors :: map()

  @doc """
  Extracts invoice JSON using the configured extraction backend.

  The `currency_hint` is the caller-provided base currency used by the
  prompt to pick a currency when several appear on the document.
  """
  @spec extract_invoice(String.t(), String.t()) ::
          {:ok, ExtractedData.t()} | {:error, term()}
  def extract_invoice(markdown, currency_hint) do
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

    with {:ok, prompt} <-
           Langfuse.fetch_prompt("extract-invoice", %{
             currency_hint: currency_hint,
             ocr_markdown: markdown
           }) do
      case Langfuse.trace_llm_generation("extract-invoice", model.id, prompt, fn ->
             ReqLLM.generate_object(model, prompt.content, schema, opts)
           end) do
        {:ok, response} ->
          response
          |> ReqLLM.Response.object()
          |> parse_extracted_data(config)

        {:error, reason} ->
          failure = request_failure(reason)

          Logger.error(
            "[LLM] Invoice extraction request failed with #{backend_summary(:extractor, config)}: #{inspect(failure)}"
          )

          {:error, failure}
      end
    else
      {:error, reason} ->
        Logger.error("[LLM] Invoice extraction prompt fetch failed: #{inspect(reason)}")
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

      with {:ok, prompt} <-
             Langfuse.fetch_prompt("verify-extraction", %{
               extracted_json: Jason.encode!(json_payload),
               ocr_markdown: markdown
             }) do
        case Langfuse.trace_llm_generation("verify-extraction", model.id, prompt, fn ->
               ReqLLM.generate_object(model, prompt.content, schema, opts)
             end) do
          {:ok, response} ->
            case verifier_object(response) do
              {:ok, %{"status" => "verified"} = verification} ->
                Logger.info(
                  "[LLM] Extraction verification completed with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
                )

                {:ok, verification}

              {:ok, %{"status" => status} = verification}
              when status in ["needs_review", "rejected"] ->
                Logger.warning(
                  "[LLM] Extraction verification returned #{status} with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
                )

                {:ok, verification}

              {:error, reason} ->
                raw_response = verifier_response_payload(response, nil)

                Logger.error(
                  "[LLM] Extraction verification returned no valid verifier output with #{backend_summary(:verifier, config)}: #{inspect(reason)} #{inspect(raw_response)}"
                )

                {:ok, verification_failure_result(raw_response, reason)}
            end

          {:error, reason} ->
            failure = request_failure(reason)

            Logger.error(
              "[LLM] Extraction verification request failed with #{backend_summary(:verifier, config)}: #{inspect(failure)}"
            )

            {:ok, verification_failure_result(%{"error" => inspect(failure)}, failure)}
        end
      else
        {:error, reason} ->
          Logger.error("[LLM] Extraction verification prompt fetch failed: #{inspect(reason)}")
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
  @spec verifier_object(ReqLLM.Response.t()) :: {:ok, map()} | {:error, term()}
  def verifier_object(response) do
    with {:ok, candidate} <- extract_verifier_object(response),
         {:ok, result} <- verification_result(candidate) do
      {:ok, result}
    else
      {:error, :no_structured_output} -> {:error, :no_structured_output}
      {:error, :verification_failed} -> {:error, :invalid_verifier_output}
    end
  end

  @doc false
  @spec extract_verifier_object(ReqLLM.Response.t()) :: {:ok, map()} | {:error, term()}
  def extract_verifier_object(response) do
    case ReqLLM.Response.object(response) do
      %{} = object ->
        {:ok, object}

      _ ->
        # Some local backends (e.g. FastFlowLM) cannot honor response_format and
        # instead return the JSON as plain text content, often wrapped in a
        # ```json ... ``` markdown fence. unwrap_object/2 routes that through
        # ReqLLM.JSON.decode (repair on), which strips the fence, extracts the
        # JSON payload, and tolerates trailing commas / smart quotes. The
        # repaired map is still validated against the verifier contract by the
        # caller before it is trusted.
        case ReqLLM.Response.unwrap_object(response, json_repair: true) do
          {:ok, %{} = object} ->
            {:ok, object}

          _ ->
            case structured_output_args(ReqLLM.Response.tool_calls(response)) do
              %{} = object -> {:ok, object}
              nil -> {:error, :no_structured_output}
            end
        end
    end
  end

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

  # FastFlowLM lacks response_format support and can emit malformed tool-call
  # arguments when producing structured output. Revisit this fallback if grammar
  # support lands: https://github.com/FastFlowLM/FastFlowLM/issues/554 and
  # https://github.com/FastFlowLM/FastFlowLM/pull/487.
  defp structured_output_args(tool_calls) do
    Enum.find_value(tool_calls, fn
      %ReqLLM.ToolCall{} = tool_call ->
        if ReqLLM.ToolCall.matches_name?(tool_call, "structured_output") do
          decode_structured_output_args(tool_call)
        end

      %{name: "structured_output", arguments: arguments} when is_map(arguments) ->
        arguments

      %{"name" => "structured_output", "arguments" => arguments} when is_map(arguments) ->
        arguments

      _ ->
        nil
    end)
  end

  defp decode_structured_output_args(tool_call) do
    case ReqLLM.ToolCall.args_map(tool_call) do
      %{} = arguments -> arguments
      nil -> decode_json_with_unescaped_markdown(ReqLLM.ToolCall.args_json(tool_call))
    end
  end

  defp decode_json_with_unescaped_markdown(arguments_json) do
    arguments_json
    |> then(&Regex.replace(~r/\\([^"\\\/bfnrtu])/, &1, fn _, character -> character end))
    |> Jason.decode()
    |> case do
      {:ok, arguments} when is_map(arguments) -> arguments
      {:error, _reason} -> nil
    end
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
  @spec request_failure(term()) :: {:llm_request_failed, String.t()}
  def request_failure(%ReqLLM.Error.API.Request{reason: reason}) when is_binary(reason),
    do: {:llm_request_failed, reason}

  def request_failure(%ReqLLM.Error.API.Request{reason: reason}) when is_atom(reason),
    do: {:llm_request_failed, Atom.to_string(reason)}

  def request_failure(%ReqLLM.Error.API.Request{}),
    do: {:llm_request_failed, "unknown request error"}

  def request_failure(_error), do: {:llm_request_failed, "unknown request error"}

  @doc false
  @spec backend_for(role()) :: backend()
  def backend_for(role) when role in [:extractor, :verifier] do
    role_config!(role) |> Keyword.fetch!(:backend) |> normalize_backend()
  end

  @doc false
  @spec model_for(role()) :: String.t()
  def model_for(role) when role in [:extractor, :verifier] do
    role_config!(role) |> Keyword.fetch!(:model)
  end

  @spec workflow_config() :: workflow_config()
  defp workflow_config, do: Application.fetch_env!(:zaimu_tomo, :ai_workflow)

  @spec role_config!(role()) :: role_config()
  defp role_config!(role), do: workflow_config() |> Keyword.fetch!(role)

  @spec backend_config!(role()) :: resolved_backend_config()
  defp backend_config!(role) do
    backend = backend_for(role)
    backend_config = Application.fetch_env!(:zaimu_tomo, backend)

    api_key =
      case Keyword.fetch!(backend_config, :api_key) do
        api_key when is_binary(api_key) and byte_size(api_key) > 0 -> api_key
        _ -> raise ArgumentError, "AI backend #{inspect(backend)} requires a non-empty api_key"
      end

    backend_config
    |> Keyword.put(:model, model_for(role))
    |> Keyword.put(:api_key, api_key)
  end

  @spec normalize_backend(backend() | String.t() | term()) :: backend()
  defp normalize_backend(backend) when backend in @backends, do: backend

  defp normalize_backend(backend) when is_binary(backend) do
    case String.downcase(backend) do
      "ollama" -> :ollama
      "flm" -> :flm
      "mistral" -> :mistral
      "nousresearch" -> :nousresearch
      unknown -> raise ArgumentError, "unknown AI backend #{inspect(unknown)}"
    end
  end

  defp normalize_backend(backend) do
    raise ArgumentError, "unknown AI backend #{inspect(backend)}"
  end

  @spec req_llm_model!(resolved_backend_config()) :: LLMDB.Model.t()
  defp req_llm_model!(config) do
    ReqLLM.model!(%{
      provider: Keyword.fetch!(config, :provider),
      id: Keyword.fetch!(config, :model),
      base_url: Keyword.fetch!(config, :base_url)
    })
  end

  @spec req_llm_opts(resolved_backend_config()) :: keyword()
  defp req_llm_opts(config) do
    [
      api_key: Keyword.fetch!(config, :api_key),
      temperature: 0.0,
      telemetry: [payloads: :none]
    ]
  end

  @spec backend_summary(role(), resolved_backend_config()) :: String.t()
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
