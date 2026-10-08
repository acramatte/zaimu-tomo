defmodule ZaimuTomo.DocumentProcessing.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.DocumentProcessing.ErrorClassification

  describe "transient errors (retried without persisting)" do
    test "scratch / temporary file creation failure" do
      assert ErrorClassification.classify({:scratch_unavailable, :enospc}) == :transient
    end

    test "storage overloaded or down (408 / 429 / 5xx)" do
      assert ErrorClassification.classify({:unexpected_status, 408}) == :transient
      assert ErrorClassification.classify({:unexpected_status, 429}) == :transient
      assert ErrorClassification.classify({:unexpected_status, 500}) == :transient
      assert ErrorClassification.classify({:unexpected_status, 503}) == :transient
    end

    test "storage transport errors" do
      assert ErrorClassification.classify(%Req.TransportError{reason: :closed}) == :transient
      assert ErrorClassification.classify(:econnrefused) == :transient
      assert ErrorClassification.classify(:enospc) == :transient
    end

    test "explicitly listed POSIX/fs atoms" do
      assert ErrorClassification.classify(:eio) == :transient
      assert ErrorClassification.classify(:emfile) == :transient
    end

    test "Mistral OCR rate limit / outage / transport" do
      assert ErrorClassification.classify({:ocr_request_failed, {:http_status, 429, "slow down"}}) ==
               :transient

      assert ErrorClassification.classify({:ocr_upload_failed, {:http_status, 429, "slow down"}}) ==
               :transient

      assert ErrorClassification.classify({:ocr_request_failed, {:http_status, 503, "down"}}) ==
               :transient

      assert ErrorClassification.classify(
               {:ocr_request_failed, %Req.TransportError{reason: :timeout}}
             ) ==
               :transient
    end

    test "prompt fetch blip" do
      assert ErrorClassification.classify({:prompt_fetch_failed, 503}) == :transient
      assert ErrorClassification.classify({:prompt_fetch_failed, 429}) == :transient

      assert ErrorClassification.classify(
               {:prompt_fetch_failed, %Req.TransportError{reason: :closed}}
             ) ==
               :transient
    end

    test "extractor LLM transport or busy provider" do
      assert ErrorClassification.classify(
               {:llm_request_failed, %{status: nil, reason: "conn refused"}}
             ) ==
               :transient

      assert ErrorClassification.classify({:llm_request_failed, %{status: 429, reason: "busy"}}) ==
               :transient

      assert ErrorClassification.classify({:llm_request_failed, %{status: 503, reason: "busy"}}) ==
               :transient

      assert ErrorClassification.classify(
               {:llm_request_failed, %{status: 409, reason: "conflict"}}
             ) ==
               :transient
    end
  end

  describe "permanent errors (persist one failed row)" do
    test "storage object gone" do
      assert ErrorClassification.classify(:not_found) == :permanent
    end

    test "storage non-transient status" do
      assert ErrorClassification.classify({:unexpected_status, 403}) == :permanent
      assert ErrorClassification.classify({:unexpected_status, 400}) == :permanent
    end

    test "Mistral OCR bad request / auth / missing config / local read" do
      assert ErrorClassification.classify({:ocr_request_failed, {:http_status, 400, "bad"}}) ==
               :permanent

      assert ErrorClassification.classify(
               {:ocr_request_failed, {:http_status, 401, "unauthorized"}}
             ) ==
               :permanent

      # OCR treats only 408/429/5xx as transient; other 4xx (incl. 409/425) are
      # permanent, unlike the extractor LLM.
      assert ErrorClassification.classify({:ocr_request_failed, {:http_status, 409, "conflict"}}) ==
               :permanent

      assert ErrorClassification.classify({:ocr_request_failed, {:http_status, 425, "too early"}}) ==
               :permanent

      assert ErrorClassification.classify({:ocr_upload_failed, "Missing Mistral API key"}) ==
               :permanent

      assert ErrorClassification.classify({:ocr_upload_failed, :enoent}) == :permanent
      assert ErrorClassification.classify(:unexpected_api_structure) == :permanent
    end

    test "prompt config / malformed prompt" do
      assert ErrorClassification.classify({:prompt_fetch_failed, 404}) == :permanent

      assert ErrorClassification.classify(
               {:prompt_fetch_failed, :langfuse_prompt_api_not_configured}
             ) ==
               :permanent

      assert ErrorClassification.classify(:langfuse_prompt_api_not_configured) == :permanent
      assert ErrorClassification.classify(:invalid_langfuse_prompt_response) == :permanent

      assert ErrorClassification.classify({:local_prompt_not_found, "extract-invoice"}) ==
               :permanent
    end

    test "extractor validation / non-retryable status" do
      assert ErrorClassification.classify({:llm_request_failed, %{status: 400, reason: "bad"}}) ==
               :permanent

      assert ErrorClassification.classify(
               {:llm_request_failed, %{status: 404, reason: "missing"}}
             ) ==
               :permanent

      assert ErrorClassification.classify({:validation_failed, %{amount: "is invalid"}}) ==
               :permanent

      assert ErrorClassification.classify(:missing_structured_output) == :permanent
    end

    test "verifier payload / persistence failure" do
      assert ErrorClassification.classify(:invalid_extraction_payload) == :permanent

      assert ErrorClassification.classify(
               {:persistence_failed, [document_id: {"is invalid", []}]}
             ) == :permanent
    end

    test "fails closed on unrecognized non-atom shapes" do
      assert ErrorClassification.classify(%{unexpected: "map"}) == :permanent
      assert ErrorClassification.classify({"not_an_atom_tag", "value"}) == :permanent
    end

    test "an unknown bare atom is permanent" do
      assert ErrorClassification.classify(:some_new_business_error) == :permanent
    end
  end

  describe "summarize/1 (bounded, body-free)" do
    test "HTTP failures summarize to stage and status, never the body" do
      assert ErrorClassification.summarize(
               {:ocr_request_failed, {:http_status, 429, "SECRET-INVOICE-TEXT"}}
             ) == "ocr_request_failed:http_429"

      assert ErrorClassification.summarize({:prompt_fetch_failed, 500}) ==
               "prompt_fetch_failed:http_500"
    end

    test "transport and LLM failures summarize to a bounded class" do
      assert ErrorClassification.summarize(
               {:ocr_upload_failed, %Req.TransportError{reason: :timeout}}
             ) == "ocr_upload_failed:transport_timeout"

      assert ErrorClassification.summarize({:llm_request_failed, %{status: 503, reason: "busy"}}) ==
               "llm_request_failed:http_503"

      assert ErrorClassification.summarize(
               {:llm_request_failed, %{status: nil, reason: "SECRET-INVOICE-TEXT"}}
             ) == "llm_request_failed:transport"
    end

    test "storage atoms, posix pairs and unknown shapes" do
      assert ErrorClassification.summarize(:enospc) == "storage:enospc"

      assert ErrorClassification.summarize({:ocr_upload_failed, :enoent}) ==
               "ocr_upload_failed:enoent"

      assert ErrorClassification.summarize(%{unexpected: "SECRET-INVOICE-TEXT"}) == "unclassified"

      assert ErrorClassification.summarize({:ocr_request_failed, "SECRET-INVOICE-TEXT"}) ==
               "unclassified"
    end
  end
end
