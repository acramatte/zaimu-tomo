defmodule ZaimuTomo.ObanFailureLogger do
  @moduledoc """
  Logs failed Oban job attempts (an `{:error, reason}` return, a raise or a
  crash), which Oban otherwise only records in `oban_jobs.errors`.

  Log lines stay body-free: a returned reason is logged only when it is a
  string (the workers return bounded summaries such as
  `ErrorClassification.summarize/1`), and a raise is logged by exception module
  and failing frame, never by message or arguments.
  """

  require Logger

  @handler_id "zaimu-tomo-oban-failure-logger"

  @doc """
  Attaches the `[:oban, :job, :exception]` handler. Safe to call repeatedly.
  """
  def attach do
    case :telemetry.attach(
           @handler_id,
           [:oban, :job, :exception],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:oban, :job, :exception], _measurements, meta, _config) do
    %{job: job, state: state, kind: kind, reason: reason, stacktrace: stacktrace} = meta

    Logger.warning(
      "[Oban] #{job.worker} job #{job.id} attempt #{job.attempt}/#{job.max_attempts} " <>
        "failed (#{state}): #{describe(kind, reason, stacktrace)}"
    )
  end

  defp describe(:error, %Oban.PerformError{reason: {:error, summary}}, _stacktrace)
       when is_binary(summary),
       do: summary

  defp describe(:error, %Oban.PerformError{}, _stacktrace), do: "error return"

  defp describe(:error, %module{}, stacktrace), do: "#{inspect(module)}#{location(stacktrace)}"

  defp describe(kind, _reason, stacktrace), do: "#{kind}#{location(stacktrace)}"

  defp location([{module, function, args_or_arity, location} | _rest]) do
    arity = if is_list(args_or_arity), do: length(args_or_arity), else: args_or_arity
    " at " <> Exception.format_stacktrace_entry({module, function, arity, location})
  end

  defp location(_stacktrace), do: ""
end
