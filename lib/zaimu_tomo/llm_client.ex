defmodule ZaimuTomo.LLMClient do
  @moduledoc """
  Local hybrid client wrapping ReqLLM for multi-agent workflows.
  """
  require Logger

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.VerificationResult
  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.Statements.ParsedStatement

  @backends [:ollama, :flm, :mistral, :nousresearch]
  @account_types FinancialAccount.account_types()

  @default_extractor_max_tokens 8192
  @default_extractor_receive_timeout 120_000
  @default_verifier_max_tokens 4096
  @default_verifier_receive_timeout 120_000

  @nullable_string {:or, [:string, nil]}
  @nullable_integer {:or, [:integer, nil]}

  @statement_line_schema [
    booking_date: [type: :string, required: true, doc: "YYYY-MM-DD"],
    value_date: [type: @nullable_string, doc: "YYYY-MM-DD"],
    description: [type: :string, required: true],
    amount_cents: [type: :pos_integer, required: true],
    direction: [type: {:in, ["debit", "credit"]}, required: true],
    original_amount_cents: [type: @nullable_integer],
    original_currency: [type: @nullable_string]
  ]

  @statement_page_schema [
    account_ref: [type: @nullable_string],
    period_start: [type: @nullable_string, doc: "YYYY-MM-DD"],
    period_end: [type: @nullable_string, doc: "YYYY-MM-DD"],
    currency: [type: @nullable_string],
    opening_balance_cents: [type: @nullable_integer],
    closing_balance_cents: [type: @nullable_integer],
    lines: [type: {:list, {:map, @statement_line_schema}}, required: true]
  ]

  @type role :: :extractor | :verifier
  @type backend :: :ollama | :flm | :mistral | :nousresearch
  @type role_config :: [
          backend: backend() | String.t(),
          model: String.t(),
          max_tokens: pos_integer() | nil,
          receive_timeout: pos_integer() | nil
        ]
  @type workflow_config :: [extractor: role_config(), verifier: role_config()]
  @type backend_config :: [
          provider: atom(),
          base_url: String.t(),
          api_key: String.t() | nil
        ]
  @type resolved_backend_config :: [
          provider: atom(),
          base_url: String.t(),
          model: String.t(),
          api_key: String.t() | nil,
          req_options: keyword()
        ]
  @type extraction_payload :: ExtractedData.t() | map()
  @type validation_errors :: map()
  @type statement_page_context :: %{
          page: pos_integer(),
          pages: pos_integer(),
          account_type: FinancialAccount.account_type(),
          currency: String.t(),
          period: {Date.t(), Date.t()} | nil
        }

  @doc """
  Extracts invoice JSON using the configured extraction backend.

  The `currency_hint` is the caller-provided base currency used by the
  prompt to pick a currency when several appear on the document.
  """
  @spec extract_invoice(String.t(), String.t()) ::
          {:ok, ExtractedData.t()} | {:error, term()}
  def extract_invoice(markdown, currency_hint) do
    case extract_invoice_with_meta(markdown, currency_hint) do
      {:ok, extracted_data, _meta} -> {:ok, extracted_data}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Extracts invoice JSON like `extract_invoice/2` and also returns the
  extractor model, backend, and prompt version that produced it so callers can
  persist run provenance alongside the extraction.
  """
  @spec extract_invoice_with_meta(String.t(), String.t()) ::
          {:ok, ExtractedData.t(), map()} | {:error, term()}
  def extract_invoice_with_meta(markdown, currency_hint) do
    config = backend_config!(:extractor)
    model = req_llm_model!(config)
    opts = Keyword.merge(req_llm_opts(config), extractor_request_opts())
    Logger.info("[LLM] Extracting invoice with #{backend_summary(:extractor, config)}")

    schema = [
      amount_to_pay_cents: [type: :integer, required: true],
      invoice_date: [type: :string, required: true],
      invoice_number: [type: :string, required: false],
      currency: [type: :string, required: true],
      reason_for_payment: [type: :string, required: false],
      issuer: [type: :string, required: true]
    ]

    case Langfuse.fetch_prompt("extract-invoice", %{
           currency_hint: currency_hint,
           ocr_markdown: markdown
         }) do
      {:ok, prompt} ->
        generate_and_parse_extraction(model, prompt, schema, opts, config)

      {:error, reason} ->
        Logger.error("[LLM] Invoice extraction prompt fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp generate_and_parse_extraction(model, prompt, schema, opts, config) do
    case Langfuse.trace_llm_generation("extract-invoice", model.id, prompt, fn ->
           ReqLLM.generate_object(model, prompt.content, schema, opts)
         end) do
      {:ok, response} ->
        with {:ok, extracted_data} <-
               response |> structured_object() |> parse_extracted_data(config) do
          meta = %{
            "extractor_model" => model.id,
            "extractor_backend" => Atom.to_string(backend_for(:extractor)),
            "prompt_version" => prompt.version
          }

          {:ok, extracted_data, meta}
        end

      {:error, reason} ->
        failure = request_failure(reason)

        Logger.error(
          "[LLM] Invoice extraction request failed with #{backend_summary(:extractor, config)}: #{inspect(failure)}"
        )

        {:error, failure}
    end
  end

  @spec parse_extracted_data({:ok, map()} | {:error, :no_structured_output}, backend_config()) ::
          {:ok, ExtractedData.t()} | {:error, term()}
  defp parse_extracted_data({:ok, data}, config) do
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

  defp parse_extracted_data({:error, :no_structured_output}, config) do
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

  defguardp is_valid_page_bounds(page, pages)
            when is_integer(page) and page >= 1 and is_integer(pages) and page <= pages

  defguardp is_valid_period(period)
            when is_nil(period) or
                   (tuple_size(period) == 2 and is_struct(elem(period, 0), Date) and
                      is_struct(elem(period, 1), Date))

  @doc """
  Reads one page of a bank or card statement with the extractor backend.

  `context` tells the prompt where the page sits and which account it belongs
  to: `%{page: 2, pages: 3, account_type: :credit_card, currency: "CHF",
  period: {~D[2026-10-01], ~D[2026-10-31]}}`, with `account_type` formatted for
  the prompt via `FinancialAccount.type_label/1`. `period` is the one an earlier
  page printed, or `nil`; it gives a date printed without a year its year.
  The answer is parsed by `ParsedStatement.parse_page/1`; one call returns at
  most one page of lines, so the output budget is bounded by the densest page.
  """
  @spec extract_statement_page(String.t(), statement_page_context()) ::
          {:ok, ParsedStatement.page()} | {:error, term()}
  def extract_statement_page(
        markdown,
        %{
          page: page,
          pages: pages,
          account_type: account_type,
          currency: currency,
          period: period
        } = context
      )
      when is_binary(markdown) and is_valid_page_bounds(page, pages) and
             account_type in @account_types and is_binary(currency) and
             byte_size(currency) == 3 and is_valid_period(period) do
    config = backend_config!(:extractor)
    model = req_llm_model!(config)
    opts = Keyword.merge(req_llm_opts(config), extractor_request_opts())

    with {:ok, prompt} <- fetch_statement_page_prompt(markdown, context),
         {:ok, response} <- generate_statement_page(model, prompt, opts, config),
         {:ok, object} <- statement_page_object(response, config) do
      parse_statement_page(object, config)
    end
  end

  @doc false
  @spec statement_page_prompt_variables(String.t(), statement_page_context()) :: map()
  def statement_page_prompt_variables(
        markdown,
        %{
          page: page,
          pages: pages,
          account_type: account_type,
          currency: currency,
          period: period
        }
      )
      when is_binary(markdown) and is_valid_page_bounds(page, pages) and
             account_type in @account_types and is_binary(currency) and
             byte_size(currency) == 3 and is_valid_period(period) do
    %{
      page: page,
      pages: pages,
      account_type: FinancialAccount.type_label(account_type),
      currency: currency,
      period: prompt_period(period),
      ocr_markdown: markdown
    }
  end

  defp prompt_period(nil), do: "none yet"

  defp prompt_period({first, last}),
    do: "#{Date.to_iso8601(first)} to #{Date.to_iso8601(last)}"

  defp fetch_statement_page_prompt(markdown, context) do
    case Langfuse.fetch_prompt(
           "extract-statement-page",
           statement_page_prompt_variables(markdown, context)
         ) do
      {:ok, prompt} ->
        {:ok, prompt}

      {:error, reason} ->
        Logger.error("[LLM] Statement page prompt fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp generate_statement_page(model, prompt, opts, config) do
    case Langfuse.trace_llm_generation("extract-statement-page", model.id, prompt, fn ->
           ReqLLM.generate_object(model, prompt.content, @statement_page_schema, opts)
         end) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        failure = request_failure(reason)

        Logger.error(
          "[LLM] Statement page request failed with #{backend_summary(:extractor, config)}: #{inspect(failure)}"
        )

        {:error, failure}
    end
  end

  defp statement_page_object(response, config) do
    case structured_object(response) do
      {:ok, object} ->
        {:ok, object}

      {:error, :no_structured_output} ->
        Logger.error(
          "[LLM] Statement page response missing structured object with #{backend_summary(:extractor, config)}"
        )

        {:error, :missing_structured_output}
    end
  end

  defp parse_statement_page(object, config) do
    case ParsedStatement.parse_page(object) do
      {:ok, page} ->
        {:ok, page}

      {:error, {:validation_failed, errors}} = error ->
        summary = backend_summary(:extractor, config)

        Logger.error(
          "[LLM] Statement page failed schema validation with #{summary}: #{inspect(errors)}"
        )

        error
    end
  end

  @doc """
  Verifies extraction against the markdown using the configured verifier backend.

  Returns `{:ok, verdict}` with the verifier's `status` (`verified`,
  `needs_review`, or `rejected`), its `reason` and `field_issues`, and the
  `verifier_model` and `prompt_version` that produced it. A failed request or
  prompt fetch returns its reason, and an answer with no valid structured
  object returns `{:invalid_verifier_output, raw_response}`, so the caller can
  classify and retry it (`DocumentProcessing.VerificationJob`).
  """
  @spec verify_extraction(String.t(), extraction_payload() | term()) ::
          {:ok, map()} | {:error, term()}
  def verify_extraction(markdown, json_data) do
    with {:ok, json_payload} <- normalize_json_data(json_data) do
      config = backend_config!(:verifier)
      model = req_llm_model!(config)
      opts = Keyword.merge(req_llm_opts(config), verifier_request_opts())
      Logger.info("[LLM] Verifying extraction with #{backend_summary(:verifier, config)}")

      schema = [
        status: [type: :string, required: true],
        reason: [type: :string, required: true],
        field_issues: [type: :string, required: false]
      ]

      case Langfuse.fetch_prompt("verify-extraction", %{
             extracted_json: Jason.encode!(json_payload),
             ocr_markdown: markdown
           }) do
        {:ok, prompt} ->
          generate_and_verify(model, prompt, schema, opts, config)

        {:error, reason} ->
          Logger.error("[LLM] Extraction verification prompt fetch failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp generate_and_verify(model, prompt, schema, opts, config) do
    case Langfuse.trace_llm_generation("verify-extraction", model.id, prompt, fn ->
           ReqLLM.generate_object(model, prompt.content, schema, opts)
         end) do
      {:ok, response} ->
        with {:ok, verdict} <- handle_verifier_response(response, config) do
          {:ok,
           Map.merge(verdict, %{"verifier_model" => model.id, "prompt_version" => prompt.version})}
        end

      {:error, reason} ->
        failure = request_failure(reason)

        Logger.error(
          "[LLM] Extraction verification request failed with #{backend_summary(:verifier, config)}: #{inspect(failure)}"
        )

        {:error, failure}
    end
  end

  defp handle_verifier_response(response, config) do
    case verifier_object(response) do
      {:ok, %{"status" => "verified"} = verification} ->
        Logger.info(
          "[LLM] Extraction verification completed with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
        )

        {:ok, verification}

      {:ok, %{"status" => status} = verification} when status in ["needs_review", "rejected"] ->
        Logger.warning(
          "[LLM] Extraction verification returned #{status} with #{backend_summary(:verifier, config)}: #{inspect(verification)}"
        )

        {:ok, verification}

      {:error, reason} ->
        raw_response = verifier_response_payload(response, nil)

        Logger.error(
          "[LLM] Extraction verification returned no valid verifier output with #{backend_summary(:verifier, config)}: #{inspect(reason)} #{inspect(raw_response)}"
        )

        {:error, {:invalid_verifier_output, raw_response}}
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
    case structured_object(response) do
      {:ok, object} -> {:ok, object}
      {:error, :no_structured_output} -> prose_object_from_response(response)
    end
  end

  # ReqLLM's :openai provider (used by nousresearch) forces a structured_output
  # tool call and leaves `object` nil when the model answers with JSON message
  # text instead, as granite-4.2-8b sometimes does. Both roles recover it here;
  # callers still validate the map against their own contract before trusting it.
  defp structured_object(response) do
    with {:error, :no_object} <- object_from_response(response),
         {:error, :no_unwrapped_object} <- unwrapped_object_from_response(response),
         {:error, :no_structured_output} <- structured_output_from_tool_calls(response) do
      {:error, :no_structured_output}
    else
      %{} = object -> {:ok, object}
    end
  end

  # Some local backends (e.g. FastFlowLM's phi4-mini) answer the verifier prompt
  # conversationally instead of emitting JSON, even though the answer carries the
  # same labeled fields ("Status: verified\nReason: ...\nField Issues: None.").
  # Recover those labels so a correctly-reasoning model is not treated as a
  # structured-output failure; VerificationResult still validates every value,
  # so unrecognized prose never becomes a verdict.
  defp prose_object_from_response(response) do
    text = ReqLLM.Response.text(response)

    case prose_fields(text) do
      %{"status" => _status} = object -> {:ok, object}
      _ -> {:error, :no_structured_output}
    end
  end

  defp prose_fields(text) when is_binary(text) do
    %{}
    |> put_prose_field(text, ~r/\bstatus:\s*([^\n]+)/i, "status")
    |> put_prose_field(text, ~r/\breason:\s*(.*?)(?:^\s*field issues:|\z)/ims, "reason")
    |> put_prose_field(text, ~r/^\s*field issues:\s*(.*?)(?:^\s*\S|\z)/ims, "field_issues")
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end

  defp prose_fields(_text), do: %{}

  defp put_prose_field(fields, text, regex, key) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value | _] -> Map.put(fields, key, value)
      _ -> fields
    end
  end

  defp object_from_response(response) do
    case ReqLLM.Response.object(response) do
      %{} = object -> object
      _ -> {:error, :no_object}
    end
  end

  defp unwrapped_object_from_response(response) do
    # Some local backends (e.g. FastFlowLM) cannot honor response_format and
    # instead return the JSON as plain text content, often wrapped in a
    # ```json ... ``` markdown fence. unwrap_object/2 routes that through
    # ReqLLM.JSON.decode (repair on), which strips the fence, extracts the
    # JSON payload, and tolerates trailing commas / smart quotes. The
    # repaired map is still validated against the extractor or verifier
    # contract by the caller before it is trusted.
    case ReqLLM.Response.unwrap_object(response, json_repair: true) do
      {:ok, %{} = object} -> object
      _ -> {:error, :no_unwrapped_object}
    end
  end

  defp structured_output_from_tool_calls(response) do
    case structured_output_args(ReqLLM.Response.tool_calls(response)) do
      %{} = object -> object
      nil -> {:error, :no_structured_output}
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
  @spec request_failure(term()) ::
          {:llm_request_failed, %{status: integer() | nil, reason: String.t()}}
  def request_failure(%ReqLLM.Error.API.Request{reason: reason, status: status})
      when is_binary(reason),
      do: {:llm_request_failed, %{status: status, reason: reason}}

  def request_failure(%ReqLLM.Error.API.Request{reason: reason, status: status})
      when is_atom(reason),
      do: {:llm_request_failed, %{status: status, reason: Atom.to_string(reason)}}

  def request_failure(%ReqLLM.Error.API.Request{status: status}),
    do: {:llm_request_failed, %{status: status, reason: "unknown request error"}}

  def request_failure(_error),
    do: {:llm_request_failed, %{status: nil, reason: "unknown request error"}}

  @doc false
  @spec extractor_max_tokens() :: pos_integer()
  def extractor_max_tokens, do: role_max_tokens(:extractor, @default_extractor_max_tokens)

  @doc false
  @spec extractor_receive_timeout() :: pos_integer()
  def extractor_receive_timeout,
    do: role_receive_timeout(:extractor, @default_extractor_receive_timeout)

  # Responses are not streamed, so nothing arrives until generation finishes and
  # ReqLLM's 30s default cuts off long generations. Oban already retries a failed
  # extraction with backoff, so ReqLLM's instant transport retries (4 requests
  # per attempt) only multiply the wait when the endpoint is stalled.
  @spec extractor_request_opts() :: keyword()
  defp extractor_request_opts do
    [
      max_tokens: extractor_max_tokens(),
      receive_timeout: extractor_receive_timeout(),
      max_retries: 0
    ]
  end

  @doc false
  @spec verifier_max_tokens() :: pos_integer()
  def verifier_max_tokens, do: role_max_tokens(:verifier, @default_verifier_max_tokens)

  @doc false
  @spec verifier_receive_timeout() :: pos_integer()
  def verifier_receive_timeout,
    do: role_receive_timeout(:verifier, @default_verifier_receive_timeout)

  # The verifier is unstreamed too, so it needs the same receive window. A
  # failed request comes back to `VerificationJob`, which classifies it and
  # retries a transient failure with backoff, so ReqLLM retries nothing.
  @spec verifier_request_opts() :: keyword()
  defp verifier_request_opts do
    [
      max_tokens: verifier_max_tokens(),
      receive_timeout: verifier_receive_timeout(),
      max_retries: 0
    ]
  end

  defp role_max_tokens(role, default) do
    case role_config!(role) |> Keyword.get(:max_tokens) do
      max_tokens when is_integer(max_tokens) and max_tokens > 0 -> max_tokens
      _ -> default
    end
  end

  defp role_receive_timeout(role, default) do
    case role_config!(role) |> Keyword.get(:receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> default
    end
  end

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
      backend_api_key!(
        Keyword.get(backend_config, :provider),
        Keyword.get(backend_config, :api_key),
        backend
      )

    backend_config
    |> Keyword.put(:model, model_for(role))
    |> Keyword.put(:api_key, api_key)
  end

  # ReqLLM's Ollama provider sends no Authorization header.
  defp backend_api_key!(:ollama, _api_key, _backend), do: nil

  defp backend_api_key!(_provider, api_key, _backend)
       when is_binary(api_key) and byte_size(api_key) > 0,
       do: api_key

  defp backend_api_key!(_provider, _api_key, backend) do
    raise ArgumentError, "AI backend #{inspect(backend)} requires a non-empty api_key"
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
    base_opts = [
      temperature: 0.0,
      telemetry: [payloads: :none],
      req_http_options: Keyword.get(config, :req_options, [])
    ]

    case Keyword.fetch!(config, :api_key) do
      nil -> base_opts
      api_key -> Keyword.put(base_opts, :api_key, api_key)
    end
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
