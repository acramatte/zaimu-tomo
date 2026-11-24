defmodule ZaimuTomo.DocumentProcessing.VerificationJob do
  @moduledoc """
  Durable verification of one extraction row, retried without rerunning OCR or
  extraction.

  Args are a self-contained command: `extracted_content_id`, `document_id`
  (so the invoice page finds the live job by document and `AttemptOutcomes`
  can tell its owner) and an optional W3C `traceparent`. The job never
  carries OCR text or extracted data: it re-derives the markdown from the
  row's `raw_llm_response` and reads the fields from the row.

  The row's `verification_status` starts as `pending`. Each attempt sends one
  verifier request (ReqLLM retries nothing) and ends in one of three ways:

    * a verdict, or a failure it will not retry, is recorded once through
      `ExtractedContentContext.record_verification/2` and the job completes;
    * a transient failure (`ErrorClassification.classify/1`) before the final
      attempt returns `{:error, code}`, and Oban tries again after 30 s,
      2 min, then 10 min;
    * an unreadable verifier answer is retried once: `AttemptOutcomes` counts
      it in `meta["invalid_outputs"]`, and a second one records
      `verification_failed`.

  A raise inside the attempt is recorded as `unclassified`. A job timeout or a
  Lifeline discard on the final attempt runs no job code, so `AttemptOutcomes`
  records that failure through `record_failure/4`. A verification failure never
  fails the document: it means a human checks the extraction.
  """
  use Oban.Worker,
    queue: :documents,
    max_attempts: 4,
    unique: [
      keys: [:extracted_content_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: :infinity
    ]

  require Logger

  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.LLMClient

  @backoff_seconds %{1 => 30, 2 => 120, 3 => 600}
  @invalid_output "invalid_verifier_output"

  @doc """
  Builds the job for a freshly saved extraction, joining the caller's trace.
  """
  @spec new_for(%{id: pos_integer(), document_id: pos_integer()}) :: Ecto.Changeset.t()
  def new_for(%{id: extraction_id, document_id: document_id}) do
    new(%{
      extracted_content_id: extraction_id,
      document_id: document_id,
      traceparent: Langfuse.traceparent()
    })
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Map.get(@backoff_seconds, attempt, 600)

  # The verifier's receive timeout fires first and comes back as a transient
  # error, so this only catches a real hang.
  @impl Oban.Worker
  def timeout(_job), do: LLMClient.verifier_receive_timeout() + :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"extracted_content_id" => extraction_id} = args} = job) do
    Langfuse.with_trace_parent(Map.get(args, "traceparent"), fn ->
      case ExtractedContentContext.get_by_id(extraction_id) do
        nil -> {:cancel, :extracted_content_deleted}
        %{verification_status: "pending"} = content -> content |> verify() |> handle(content, job)
        _decided -> {:cancel, :already_recorded}
      end
    end)
  end

  @doc """
  Records `verification_failed` for a job that gave up, with the failure
  `code`, the attempt it stopped on, and the unreadable answers it counted.
  """
  @spec record_failure(pos_integer(), String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, term()} | {:error, :not_found | :already_recorded}
  def record_failure(extraction_id, code, attempts, invalid_outputs) do
    ExtractedContentContext.record_verification(extraction_id, %{
      "status" => "verification_failed",
      "reason" => reason_text(code),
      "error" => code,
      "attempts" => attempts,
      "invalid_outputs" => invalid_outputs
    })
  end

  defp verify(content) do
    with {:ok, markdown, _raw} <- DocumentOCR.extract_markdown(content.raw_llm_response) do
      LLMClient.verify_extraction(markdown, content.extracted_data)
    end
  rescue
    exception ->
      Logger.error("[LLM] Verification crashed: #{inspect(exception.__struct__)}")
      {:error, :crashed}
  end

  defp handle({:ok, verdict}, content, job) do
    verdict
    |> Map.merge(%{"attempts" => job.attempt, "invalid_outputs" => invalid_outputs(job)})
    |> then(&ExtractedContentContext.record_verification(content.id, &1))
    |> recorded()
  end

  defp handle({:error, {:invalid_verifier_output, _raw}}, content, job) do
    if invalid_outputs(job) == 0 and not final_attempt?(job),
      do: {:error, @invalid_output},
      else: give_up(content, job, @invalid_output)
  end

  defp handle({:error, :crashed}, content, job), do: give_up(content, job, "unclassified")

  defp handle({:error, reason}, content, job) do
    code = ErrorClassification.summarize({:verifier, reason})

    if ErrorClassification.classify(reason) == :transient and not final_attempt?(job),
      do: {:error, code},
      else: give_up(content, job, code)
  end

  defp give_up(content, job, code) do
    counted = if code == @invalid_output, do: 1, else: 0

    Logger.warning("[LLM] Verification gave up on attempt #{job.attempt}: #{code}")

    content.id
    |> record_failure(code, job.attempt, invalid_outputs(job) + counted)
    |> recorded()
  end

  defp recorded({:ok, _content}), do: :ok
  defp recorded({:error, :not_found}), do: {:cancel, :extracted_content_deleted}
  defp recorded({:error, :already_recorded}), do: {:cancel, :already_recorded}

  defp invalid_outputs(%Oban.Job{meta: meta}), do: Map.get(meta || %{}, "invalid_outputs", 0)

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  defp reason_text(code), do: "Could not verify: #{ErrorClassification.describe(code)}."
end
