defmodule ZaimuTomo.Langfuse do
  @moduledoc """
  Langfuse tracing for the document-processing workflow.
  """

  @tracer_name :zaimu_tomo

  @spec setup() :: :ok
  def setup, do: :ok

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

  @spec enabled?() :: boolean()
  def enabled?,
    do: Application.get_env(:zaimu_tomo, :langfuse, []) |> Keyword.get(:enabled, false)

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
      "langfuse.observation.model.name" => model,
      "gen_ai.request.model" => model,
      "langfuse.observation.input" => encode_json(%{"prompt" => prompt})
    }
  end

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
      "gen_ai.usage.output_tokens" => usage_value(response, :output)
    }
    |> compact_attributes()
  end

  defp usage_value(response, key) do
    usage = Map.get(response, :usage, %{})
    tokens = Map.get(usage, :tokens, usage)

    Map.get(tokens, key) || Map.get(tokens, "#{key}_tokens")
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
    Application.get_env(:zaimu_tomo, :langfuse, [])
    |> Keyword.get(:environment, "development")
  end
end
