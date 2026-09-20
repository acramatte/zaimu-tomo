defmodule ZaimuTomo.TypeSafeVerification.Worker do
  @moduledoc false

  require Logger

  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.TypeSafeClient

  @spec perform(map()) :: :ok
  def perform(%{trace_context: trace_context} = command) do
    token = OpenTelemetry.Ctx.attach(trace_context)

    try do
      command |> Map.delete(:trace_context) |> perform()
    after
      OpenTelemetry.Ctx.detach(token)
    end
  end

  def perform(%{
        extracted_content_id: extraction_id,
        markdown: markdown,
        extracted_data: extracted_data,
        currency_hint: currency_hint
      }) do
    Logger.info("[TypeSafe] Shadow verification started")

    result =
      Langfuse.trace_span("typesafe-shadow-verification", span_attributes(), fn ->
        safely_verify(markdown, extracted_data, currency_hint)
      end)

    persist_result(extraction_id, result)
  end

  defp safely_verify(markdown, extracted_data, currency_hint) do
    TypeSafeClient.verify_extraction(markdown, extracted_data, currency_hint)
  rescue
    exception ->
      record_unexpected_failure({:exception, exception.__struct__}, __STACKTRACE__)
  catch
    kind, _reason when kind in [:exit, :throw] ->
      record_unexpected_failure(kind, __STACKTRACE__)
  end

  defp record_unexpected_failure(reason, stacktrace) do
    error = error_class(reason)
    sanitized_stacktrace = sanitize_stacktrace(stacktrace)

    Logger.error(
      "[TypeSafe] Shadow verification crashed class=#{error}\n#{sanitized_stacktrace}",
      typesafe_error_class: error,
      typesafe_stacktrace: sanitized_stacktrace
    )

    {:error, reason}
  end

  defp sanitize_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn {module, function, args_or_arity, location} ->
      arity = if is_list(args_or_arity), do: length(args_or_arity), else: args_or_arity
      {module, function, arity, Keyword.take(location, [:file, :line])}
    end)
    |> Exception.format_stacktrace()
  end

  defp persist_result(extraction_id, {:ok, shadow}) do
    case ExtractedContentContext.put_typesafe_shadow(extraction_id, shadow) do
      {:ok, _content} ->
        Logger.info("[TypeSafe] Shadow verification succeeded #{log_metadata(shadow)}",
          typesafe_status: shadow["status"],
          typesafe_model: shadow["model"]
        )

        :ok

      {:error, reason} ->
        error = error_class(reason)

        Logger.warning("[TypeSafe] Shadow verification persistence failed class=#{error}",
          typesafe_error_class: error
        )

        :ok
    end
  end

  defp persist_result(_extraction_id, :disabled), do: :ok

  defp persist_result(extraction_id, {:error, reason}) do
    error = error_class(reason)

    Logger.warning("[TypeSafe] Shadow verification failed class=#{error}",
      typesafe_error_class: error
    )

    shadow = %{
      "status" => "verification_failed",
      "error" => error
    }

    case ExtractedContentContext.put_typesafe_shadow(extraction_id, shadow) do
      {:ok, _content} ->
        :ok

      {:error, persistence_reason} ->
        persistence_error = error_class(persistence_reason)

        Logger.warning(
          "[TypeSafe] Shadow verification persistence failed class=#{persistence_error}",
          typesafe_error_class: persistence_error
        )

        :ok
    end
  end

  defp log_metadata(shadow) do
    [
      "status=#{shadow["status"]}",
      "model=#{shadow["model"]}",
      "max_error_probability=#{shadow["max_error_probability"]}",
      "review_threshold=#{shadow["review_threshold"]}"
    ]
    |> Enum.join(" ")
  end

  defp error_class({:http, status}) when is_integer(status), do: "http_#{status}"
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({kind, reason}) when is_atom(kind) and is_atom(reason), do: "#{kind}:#{reason}"
  defp error_class(_reason), do: "unknown"

  defp span_attributes do
    config = Application.get_env(:zaimu_tomo, :typesafe, [])

    %{
      "langfuse.observation.model.name" => Keyword.get(config, :model, "jev-latest"),
      "gen_ai.request.model" => Keyword.get(config, :model, "jev-latest")
    }
  end
end
