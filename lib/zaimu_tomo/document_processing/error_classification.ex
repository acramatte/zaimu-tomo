defmodule ZaimuTomo.DocumentProcessing.ErrorClassification do
  @moduledoc """
  Pure classification of document-processing failure reasons by retryability.

  The OCR pipeline emits a variety of error shapes (storage, HTTP clients, LLM
  wrappers, prompt fetch, persistence). `classify/1` maps each to:

    * `:transient` — worth retrying (rate limits, outages, network/fs blips).
      The job returns `{:error, reason}` WITHOUT persisting; Oban backs off and
      retries, and persists a single failed row only on the final attempt.

    * `:permanent` — retrying cannot help (bad request, missing config, invalid
      payload, missing bytes). The job persists one failed row and completes.

  Classification is pattern-matched on the exact shapes the pipeline emits (see
  `ZaimuTomo.DocumentProcessing.Worker.run/1`). It fails closed to `:permanent`
  for unrecognized non-atom shapes so a new bug never silently multiplies
  retries. Bare atoms reaching this module are storage filesystem errors
  (transient) unless listed below as permanent.
  """

  @type class :: :transient | :permanent

  # Storage / OCR / prompt: 408, 429 and 5xx are transient (rate limit/outage).
  @transient_statuses [408, 429]
  # The extractor LLM additionally treats 409/425 as transient (provider busy).
  @transient_llm_statuses [408, 409, 425, 429]
  @transient_status_max 500

  @doc """
  Classify a processing failure `reason` as `:transient` or `:permanent`.
  """
  @spec classify(term()) :: class()

  # -- Scratch / temporary file ------------------------------------------
  # Disk full or a tmp blip: retry.
  def classify({:scratch_unavailable, _posix}), do: :transient

  # -- Storage (S3 / memory) --------------------------------------------
  # Store overloaded or down (408/429/5xx).
  def classify({:unexpected_status, status}) when status in @transient_statuses,
    do: :transient

  def classify({:unexpected_status, status}) when status >= @transient_status_max,
    do: :transient

  # e.g. 403 signature/config, 400 bad request.
  def classify({:unexpected_status, _status}), do: :permanent

  # -- Prompt fetch (Langfuse) ------------------------------------------
  # Langfuse blip: a rate-limit/outage status or a transport error.
  def classify({:prompt_fetch_failed, status})
      when is_integer(status) and
             (status in @transient_statuses or status >= @transient_status_max),
      do: :transient

  def classify({:prompt_fetch_failed, %Req.TransportError{}}), do: :transient
  # Any other prompt failure (config, bad key, malformed prompt) is permanent.
  def classify({:prompt_fetch_failed, _other}), do: :permanent
  def classify({:local_prompt_not_found, _name}), do: :permanent

  # -- Extractor LLM ----------------------------------------------------
  # No status means a transport error.
  def classify({:llm_request_failed, %{status: nil}}), do: :transient

  # Provider / FLM busy.
  def classify({:llm_request_failed, %{status: status}})
      when status in @transient_llm_statuses or status >= @transient_status_max,
      do: :transient

  # 400 / 401 / 404 and other non-retryable statuses.
  def classify({:llm_request_failed, %{status: _status}}), do: :permanent
  def classify({:validation_failed, _errors}), do: :permanent

  # -- Mistral OCR ------------------------------------------------------
  # Local read of a just-written temp file failing (a bare posix atom) is a bug,
  # not a blip. HTTP/upload failures carry an {:http_status, ...} or transport
  # detail and are handled by the stage-tagged clauses below.
  def classify({:ocr_upload_failed, posix}) when is_atom(posix), do: :permanent

  # -- Persistence ------------------------------------------------------
  def classify({:persistence_failed, _errors}), do: :permanent

  # -- Mistral OCR (stage-tagged detail) --------------------------------
  # Rate limit / outage.
  def classify({_stage, {:http_status, status, _body}})
      when status in @transient_statuses or status >= @transient_status_max,
      do: :transient

  # Other 4xx: bad request / auth.
  def classify({_stage, {:http_status, _status, _body}}), do: :permanent
  # Timeout / connection refused.
  def classify({_stage, %Req.TransportError{}}), do: :transient
  # Missing config; needs a deploy, not a retry.
  def classify({_stage, "Missing Mistral API key"}), do: :permanent

  # -- Known permanent bare atoms --------------------------------------
  # The stored bytes are gone; a retry cannot help.
  def classify(:not_found), do: :permanent
  # Provider returned an unexpected body shape.
  def classify(:unexpected_api_structure), do: :permanent
  def classify(:missing_structured_output), do: :permanent
  def classify(:invalid_extraction_payload), do: :permanent
  def classify(:langfuse_prompt_api_not_configured), do: :permanent
  def classify(:invalid_langfuse_prompt_response), do: :permanent
  def classify(:prompt_fetcher_failed), do: :permanent

  # -- Storage transport (bare posix / transport) ----------------------
  # Bare atoms reaching here are storage filesystem errors (enospc, eacces, ...):
  # transient network/fs blips. Non-transport bare atoms are matched above.
  def classify(%Req.TransportError{}), do: :transient
  def classify(reason) when is_atom(reason), do: :transient

  # Fail closed: any unrecognized non-atom shape is permanent so a new bug never
  # silently multiplies retries.
  def classify(_other), do: :permanent
end
