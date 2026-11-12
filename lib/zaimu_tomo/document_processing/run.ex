defmodule ZaimuTomo.DocumentProcessing.Run do
  @moduledoc """
  A document's live OCR run, read from its Oban job.

  `attempt` is the attempt that is running, or the one that runs next while
  the job waits (Oban counts an attempt when it starts one). `last_error` is
  the failure code of the latest failed attempt, which `AttemptOutcomes` stores
  in the job's `meta["last_error"]` (see `AttemptOutcomes.failure_code/1`), or
  nil before any attempt failed. `trigger` says whether the user started the
  run with Retry processing. Build runs with
  `ZaimuTomo.DocumentProcessing.live_runs/1`.
  """

  @enforce_keys [:attempt, :max_attempts, :phase, :trigger, :started_at]
  defstruct [
    :attempt,
    :max_attempts,
    :phase,
    :last_error,
    :next_attempt_at,
    :trigger,
    :started_at
  ]

  @type phase :: :queued | :running | :waiting_to_retry
  @type trigger :: :upload | :manual_retry

  @type t :: %__MODULE__{
          attempt: pos_integer(),
          max_attempts: pos_integer(),
          phase: phase(),
          last_error: String.t() | nil,
          next_attempt_at: DateTime.t() | nil,
          trigger: trigger(),
          started_at: DateTime.t()
        }

  @phases %{
    "available" => :queued,
    "scheduled" => :queued,
    "executing" => :running,
    "retryable" => :waiting_to_retry
  }

  @doc "Job meta that records what started a run."
  @spec job_meta(trigger()) :: map()
  def job_meta(trigger) when trigger in [:upload, :manual_retry],
    do: %{"trigger" => Atom.to_string(trigger)}

  @doc false
  @spec from_job(Oban.Job.t()) :: t()
  def from_job(%Oban.Job{} = job) do
    phase = Map.fetch!(@phases, job.state)

    %__MODULE__{
      attempt: if(phase == :running, do: job.attempt, else: job.attempt + 1),
      max_attempts: job.max_attempts,
      phase: phase,
      last_error: job.meta["last_error"],
      next_attempt_at: if(phase == :waiting_to_retry, do: job.scheduled_at),
      trigger: trigger(job.meta),
      started_at: job.inserted_at
    }
  end

  @doc """
  True when the run is a retry: the user started it after a failed or stalled
  run, or an earlier attempt of this run failed. Waiting to retry implies a
  later attempt, so it is covered too.
  """
  @spec retrying?(t()) :: boolean()
  def retrying?(%__MODULE__{trigger: :manual_retry}), do: true
  def retrying?(%__MODULE__{attempt: attempt}), do: attempt > 1

  defp trigger(%{"trigger" => "manual_retry"}), do: :manual_retry
  defp trigger(_meta), do: :upload
end
