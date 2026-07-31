defmodule ZaimuTomo.Langfuse do
  @moduledoc """
  Langfuse tracing for the document-processing workflow.
  """

  @tracer_name :zaimu_tomo

  defmodule Prompt do
    @enforce_keys [:id, :name, :version, :label, :content]
    defstruct [:id, :name, :version, :label, :content]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            version: non_neg_integer(),
            label: String.t(),
            content: String.t()
          }
  end

  @spec setup() :: :ok
  def setup, do: :ok

  @spec fetch_prompt(String.t(), map()) :: {:ok, Prompt.t()} | {:error, term()}
  def fetch_prompt(name, variables) when is_binary(name) and is_map(variables) do
    label = "production"

    with {:ok, {id, prompt_name, version, template}} <- fetch_prompt_source(name, label),
         {:ok, content} <- compile_prompt(template, variables) do
      {:ok,
       %Prompt{
         id: id,
         name: prompt_name,
         version: version,
         label: label,
         content: content
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec trace_document_processing(map(), (-> result)) :: result when result: term()
  def trace_document_processing(%{id: document_id, user_id: user_id}, fun)
      when is_function(fun, 0) do
    trace_document_processing(enabled?(), document_id, user_id, fun)
  end

  defp trace_document_processing(true, document_id, user_id, fun) do
    :otel_tracer.with_span(
      tracer(),
      "process-invoice",
      %{kind: :internal, attributes: initial_attributes(document_id, user_id)},
      fn span ->
        result = fun.()
        record_result(span, result)
        result
      end
    )
  end

  defp trace_document_processing(false, _document_id, _user_id, fun), do: fun.()

  @spec trace_llm_generation(String.t(), String.t(), String.t(), (-> result)) :: result
        when result: term()
  def trace_llm_generation(name, model, prompt, fun)
      when is_binary(name) and is_binary(model) and is_binary(prompt) and is_function(fun, 0) do
    trace_llm_generation(enabled?(), name, model, prompt, fun)
  end

  @spec trace_llm_generation(String.t(), String.t(), Prompt.t(), (-> result)) :: result
        when result: term()
  def trace_llm_generation(name, model, %Prompt{} = prompt, fun)
      when is_binary(name) and is_binary(model) and is_function(fun, 0) do
    trace_llm_generation(enabled?(), name, model, prompt, fun)
  end

  defp trace_llm_generation(true, name, model, prompt, fun) do
    :otel_tracer.with_span(
      tracer(),
      name,
      %{kind: :client, attributes: generation_attributes(model, prompt)},
      fn span ->
        result = fun.()
        record_generation_result(span, result)
        result
      end
    )
  end

  defp trace_llm_generation(false, _name, _model, _prompt, fun), do: fun.()

  defp prompt_fetcher do
    config() |> Keyword.get(:prompt_fetcher, &fetch_prompt_from_api/2)
  end

  defp fetch_prompt_source(name, label) do
    fetch_prompt_source(enabled?(), name, label)
  end

  defp fetch_prompt_source(true, name, label) do
    name
    |> fetch_prompt_result(label)
    |> parse_prompt_response()
  end

  defp fetch_prompt_source(false, name, _label), do: fetch_local_prompt(name)

  defp fetch_prompt_result(name, label) do
    try do
      prompt_fetcher().(name, label)
    rescue
      _exception -> {:error, :prompt_fetcher_failed}
    catch
      _kind, _reason -> {:error, :prompt_fetcher_failed}
    end
  end

  defp parse_prompt_response(
         {:ok,
          %{
            "id" => id,
            "name" => name,
            "version" => version,
            "prompt" => template
          }}
       )
       when is_binary(id) and is_binary(name) and is_integer(version) and version >= 0 and
              is_binary(template),
       do: {:ok, {id, name, version, template}}

  defp parse_prompt_response({:ok, _prompt}), do: {:error, :invalid_langfuse_prompt_response}
  defp parse_prompt_response({:error, _reason} = error), do: error
  defp parse_prompt_response(_response), do: {:error, :invalid_langfuse_prompt_response}

  defp fetch_local_prompt("extract-invoice") do
    {:ok,
     {"local:extract-invoice", "extract-invoice", 0,
      """
      Extract invoice fields from the OCR text.

      Rules:
      - Return only structured output matching the schema.
      - Never ask a question and never request clarification.
      - If multiple currencies appear, choose {{currency_hint}} when present.
      - If {{currency_hint}} is not present, choose the final amount charged or payable.
      - Put the chosen ISO 4217 currency code in currency.
      - Put the chosen amount in amount_to_pay_cents.
      - Put invoice_date in ISO 8601 YYYY-MM-DD format.
      - Use reason_for_payment for a short payment description.

      OCR Text:
      {{ocr_markdown}}
      """}}
  end

  defp fetch_local_prompt("verify-extraction") do
    {:ok,
     {"local:verify-extraction", "verify-extraction", 0,
      """
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
      {{extracted_json}}

      Source OCR Markdown:
      {{ocr_markdown}}
      """}}
  end

  defp fetch_local_prompt(name), do: {:error, {:local_prompt_not_found, name}}

  defp fetch_prompt_from_api(name, label) do
    with {:ok, base_url, public_key, secret_key} <- prompt_api_config(),
         {:ok, %Req.Response{status: 200, body: prompt}} <-
           Req.get("#{base_url}/api/public/v2/prompts/#{URI.encode(name)}",
             params: [label: label],
             headers: [{"authorization", basic_auth(public_key, secret_key)}]
           ) do
      {:ok, prompt}
    else
      {:ok, %Req.Response{} = response} -> {:error, {:prompt_fetch_failed, response.status}}
      {:error, reason} -> {:error, {:prompt_fetch_failed, reason}}
    end
  end

  defp prompt_api_config do
    with base_url when is_binary(base_url) and base_url != "" <- Keyword.get(config(), :base_url),
         public_key when is_binary(public_key) and public_key != "" <-
           Keyword.get(config(), :public_key),
         secret_key when is_binary(secret_key) and secret_key != "" <-
           Keyword.get(config(), :secret_key) do
      {:ok, base_url, public_key, secret_key}
    else
      _ -> {:error, :langfuse_prompt_api_not_configured}
    end
  end

  defp basic_auth(public_key, secret_key),
    do: "Basic " <> Base.encode64("#{public_key}:#{secret_key}")

  defp compile_prompt(template, variables) when is_binary(template) do
    variables = Map.new(variables, fn {key, value} -> {to_string(key), to_string(value)} end)

    missing_variables =
      Regex.scan(~r/{{([^{}]+)}}/, template, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(variables, &1))

    if missing_variables == [] do
      {:ok,
       Regex.replace(~r/{{([^{}]+)}}/, template, fn _, variable ->
         Map.fetch!(variables, variable)
       end)}
    else
      {:error, {:missing_prompt_variables, missing_variables}}
    end
  end

  defp compile_prompt(_template, _variables), do: {:error, :invalid_langfuse_prompt_response}

  @spec enabled?() :: boolean()
  def enabled?, do: config() |> Keyword.get(:enabled, false)

  defp tracer do
    :otel_tracer_provider.get_tracer(
      @tracer_name,
      application_version(),
      "https://opentelemetry.io/schemas/1.37.0"
    )
  end

  defp initial_attributes(document_id, user_id) do
    %{
      "langfuse.trace.name" => "process-invoice",
      "langfuse.environment" => environment(),
      "langfuse.user.id" => to_string(user_id),
      "langfuse.release" => application_version(),
      "langfuse.trace.tags" => ["document-processing", environment()],
      "langfuse.trace.metadata.document_id" => to_string(document_id),
      "langfuse.trace.metadata.workflow" => "invoice-processing",
      "langfuse.observation.input" => encode_json(%{"workflow" => "invoice-processing"})
    }
  end

  defp generation_attributes(model, prompt) do
    %{
      "langfuse.observation.type" => "generation",
      "langfuse.environment" => environment(),
      "langfuse.observation.model.name" => model,
      "gen_ai.request.model" => model,
      "langfuse.observation.input" => encode_json(%{"prompt" => prompt_content(prompt)})
    }
    |> Map.merge(prompt_attributes(prompt))
  end

  defp prompt_content(%Prompt{content: content}), do: content
  defp prompt_content(content), do: content

  defp prompt_attributes(%Prompt{} = prompt) do
    %{
      "langfuse.observation.prompt.name" => prompt.name,
      "langfuse.observation.prompt.version" => prompt.version
    }
  end

  defp prompt_attributes(_prompt), do: %{}

  defp record_generation_result(span, {:ok, response}) do
    :otel_span.set_attributes(span, generation_output_attributes(response))
  end

  defp record_generation_result(span, _result) do
    :otel_span.set_attributes(span, %{
      "langfuse.observation.output" => encode_json(%{"status" => "failed"})
    })

    :otel_span.set_status(span, :error, "LLM request failed")
  end

  defp generation_output_attributes(response) do
    %{
      "langfuse.observation.output" =>
        encode_json(%{
          "object" => ReqLLM.Response.object(response),
          "text" => ReqLLM.Response.text(response)
        }),
      "gen_ai.usage.input_tokens" => usage_value(response, :input),
      "gen_ai.usage.output_tokens" => usage_value(response, :output),
      "gen_ai.usage.cost" => usage_value(response, :total_cost)
    }
    |> compact_attributes()
  end

  defp usage_value(response, :total_cost) do
    usage = Map.get(response, :usage, %{})

    Map.get(usage, :total_cost) || Map.get(usage, "total_cost")
  end

  defp usage_value(response, key) when key in [:input, :output] do
    usage = Map.get(response, :usage, %{})
    tokens = Map.get(usage, :tokens, usage)

    token_key = if key == :input, do: :input_tokens, else: :output_tokens

    Map.get(tokens, key) ||
      Map.get(tokens, "#{key}") ||
      Map.get(tokens, token_key) ||
      Map.get(tokens, "#{key}_tokens")
  end

  defp record_result(span, {:ok, %{status: "success"}}) do
    :otel_span.set_attributes(span, %{
      "langfuse.observation.output" => encode_json(%{"status" => "success"})
    })
  end

  defp record_result(span, {:ok, %{status: "failed"}}) do
    record_document_failure(span)
  end

  defp record_result(span, {:error, _reason}) do
    record_document_failure(span)
  end

  defp record_result(span, _result) do
    :otel_span.set_attributes(span, %{
      "langfuse.observation.output" => encode_json(%{"status" => "completed"})
    })
  end

  defp record_document_failure(span) do
    :otel_span.set_attributes(span, %{
      "langfuse.observation.output" => encode_json(%{"status" => "failed"})
    })

    :otel_span.set_status(span, :error, "document processing failed")
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> Jason.encode!(%{"unavailable" => true})
    end
  end

  defp compact_attributes(attributes) do
    Map.reject(attributes, fn {_key, value} -> is_nil(value) end)
  end

  defp application_version do
    :zaimu_tomo
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp environment do
    config()
    |> Keyword.get(:environment, "development")
  end

  defp config, do: Application.get_env(:zaimu_tomo, :langfuse, [])
end
