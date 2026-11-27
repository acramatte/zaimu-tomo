defmodule ZaimuTomo.Datasets.Record do
  @moduledoc """
  Pure assembler turning one `%Document{}` (with preloaded extractions, review
  decisions, and journal entries) plus optional S3 check, Langfuse enrichment,
  and human audit overlay into a schema-v1 canonical dataset record.
  """

  alias ZaimuTomo.Datasets.Splits
  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Review.ReviewDecision

  @schema_version 1
  @required_ground_truth_fields ~w(amount_to_pay_cents currency invoice_date issuer)
  @optional_ground_truth_fields ~w(invoice_number reason_for_payment)

  @doc "The canonical dataset schema version produced by this module."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Returns true when `document` has a successful extraction and an eligible
  review decision under `context` (`%{include_pending: boolean()}`).
  """
  @spec eligible?(Document.t(), map()) :: boolean()
  def eligible?(%Document{} = document, context) when is_map(context) do
    match?({:ok, _, _, _}, select_latest_eligible(document, context))
  end

  @doc """
  Builds a canonical dataset map for `document`, or returns `:skip` when the
  document does not match the eligibility options (`include_pending`).
  """
  @spec build(Document.t(), map()) :: {:ok, map()} | :skip
  def build(%Document{} = document, context) when is_map(context) do
    case select_latest_eligible(document, context) do
      {:ok, runs, latest, decision} ->
        {:ok, assemble(document, runs, latest, decision, context)}

      :skip ->
        :skip
    end
  end

  defp select_latest_eligible(document, context) do
    runs = Enum.sort(document.extracted_content || [], &compare_runs/2)
    latest_success = runs |> Enum.filter(&(&1.status == "success")) |> List.last()

    with %ExtractedContent{} = latest <- latest_success,
         %ReviewDecision{} = decision <- latest.review_decision,
         true <- eligible_decision?(decision, context) do
      {:ok, runs, latest, decision}
    else
      _ -> :skip
    end
  end

  defp compare_runs(a, b) do
    case compare_timestamps(a.inserted_at, b.inserted_at) do
      :lt -> true
      :gt -> false
      :eq -> (a.id || 0) <= (b.id || 0)
    end
  end

  defp compare_timestamps(%NaiveDateTime{} = a, %NaiveDateTime{} = b),
    do: NaiveDateTime.compare(a, b)

  defp compare_timestamps(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare_timestamps(nil, nil), do: :eq
  defp compare_timestamps(nil, _b), do: :lt
  defp compare_timestamps(_a, nil), do: :gt

  defp eligible_decision?(%ReviewDecision{review_status: status}, _context)
       when status in ["approved", "amended", "rejected"],
       do: true

  defp eligible_decision?(%ReviewDecision{review_status: "pending"}, %{include_pending: true}),
    do: true

  defp eligible_decision?(_decision, _context), do: false

  defp assemble(document, runs, latest, decision, context) do
    overlay = Map.get(context[:audit_overlay] || %{}, document.id)
    scores_by_trace = context[:scores_by_trace] || %{}
    obs_by_trace = context[:observations_by_trace] || %{}

    human_thumbs = resolve_human_thumbs(decision, latest.trace_id, scores_by_trace)
    pages = ocr_pages(latest.raw_llm_response)
    markdown = Enum.map_join(pages, "\n\n", & &1["markdown"])
    currency_hint = currency_hint(latest, context[:user_base_currency])

    ground_truth = build_ground_truth(decision, human_thumbs, overlay)
    issuer_source = ground_truth_issuer(ground_truth, latest.extracted_data)

    %{
      "dataset_schema_version" => @schema_version,
      "document_type" => "invoice",
      "document_id" => document.id,
      "document" => %{
        "filename" => document.filename,
        "mime_type" => MIME.from_path(document.filename || document.object_key || ""),
        "s3_key" => document.object_key,
        "s3_exists" => context[:s3_exists],
        "content_sha256" => document.content_sha256,
        "file_matches_posted_snapshot" =>
          file_matches_snapshot?(document, decision.journal_entry),
        "page_count" => length(pages)
      },
      "inputs" => %{
        "currency_hint" => currency_hint,
        "ocr" => %{
          "provider" => "mistral",
          "model" => ocr_model(latest),
          "markdown" => markdown,
          "pages" => pages
        }
      },
      "ground_truth" => ground_truth,
      "label" => build_label(decision, human_thumbs, ground_truth["extracted_faithful"], overlay),
      "processing_runs" => Enum.map(runs, &build_run(&1, obs_by_trace, scores_by_trace)),
      "grouping" => %{
        "issuer_norm" => Splits.normalize_issuer(issuer_source),
        "split" => nil,
        "challenge_eval" => false
      }
    }
  end

  defp resolve_human_thumbs(%ReviewDecision{extraction_feedback: val}, _trace_id, _scores)
       when is_boolean(val),
       do: val

  defp resolve_human_thumbs(_decision, trace_id, scores_by_trace) when is_binary(trace_id) do
    case Map.get(scores_by_trace, trace_id) do
      %{"value" => val} when is_boolean(val) -> val
      _ -> nil
    end
  end

  defp resolve_human_thumbs(_decision, _trace_id, _scores), do: nil

  defp build_ground_truth(%ReviewDecision{review_status: status} = decision, thumbs, overlay)
       when status in ["approved", "amended"] do
    original = decision.original_data || %ExtractedData{}
    effective = ReviewDecision.effective_data(decision)

    base_faithful =
      case {status, thumbs} do
        {"approved", _} -> serialize_data(original)
        {"amended", true} -> serialize_data(original)
        {"amended", false} -> serialize_data(effective)
        {"amended", nil} -> nil
      end

    extracted_faithful = apply_overlay_fields(base_faithful, overlay)

    %{
      "extracted_faithful" => extracted_faithful,
      "booked_values" => serialize_data(effective),
      "field_diff" => build_field_diff(original, effective, thumbs)
    }
  end

  defp build_ground_truth(_decision, _thumbs, overlay) do
    %{
      "extracted_faithful" => apply_overlay_fields(nil, overlay),
      "booked_values" => nil,
      "field_diff" => []
    }
  end

  defp apply_overlay_fields(base, %{"extracted_faithful" => fields})
       when is_map(base) and is_map(fields) do
    Map.merge(base, fields)
  end

  defp apply_overlay_fields(nil, %{"extracted_faithful" => fields}) when is_map(fields) do
    if Enum.all?(@required_ground_truth_fields, &(not is_nil(Map.get(fields, &1)))) do
      @optional_ground_truth_fields
      |> Map.new(&{&1, nil})
      |> Map.merge(fields)
    else
      nil
    end
  end

  defp apply_overlay_fields(base, _overlay), do: base

  defp build_field_diff(original, effective, thumbs) do
    kind =
      case thumbs do
        true -> "personal_enrichment"
        false -> "extraction_error"
        nil -> "unclassified"
      end

    original
    |> ExtractedData.changes(effective)
    |> Enum.map(fn {field, from_val, to_val} ->
      %{
        "field" => Atom.to_string(field),
        "from" => from_val,
        "to" => to_val,
        "kind" => kind
      }
    end)
  end

  defp build_label(decision, human_thumbs, extracted_faithful, overlay) do
    quality = resolve_label_quality(decision.review_status, extracted_faithful, overlay)

    %{
      "quality" => quality,
      "review_status" => decision.review_status,
      "reviewed_at" => format_datetime(decision.review_completed_at),
      "human_thumbs" => human_thumbs,
      "ocr_faithful" => overlay && overlay["ocr_faithful"],
      "error_tags" => (overlay && overlay["error_tags"]) || []
    }
  end

  defp resolve_label_quality(_status, %{} = _faithful, %{} = overlay),
    do: overlay["quality"] || "gold_audited"

  defp resolve_label_quality("approved", _faithful, _overlay), do: "gold_reviewed"
  defp resolve_label_quality("amended", %{} = _faithful, _overlay), do: "gold_reviewed"
  defp resolve_label_quality("amended", nil, _overlay), do: "amended_unclassified"
  defp resolve_label_quality("rejected", _faithful, _overlay), do: "rejected"
  defp resolve_label_quality(_other, _faithful, _overlay), do: "unreviewed"

  defp build_run(content, obs_by_trace, scores_by_trace) do
    analysis = content.analysis || %{}
    ext_meta = Map.get(analysis, "extraction") || %{}
    verif = Map.get(analysis, "verification") || %{}
    shadow = Map.get(verif, "typesafe_shadow")
    trace_obs = (content.trace_id && Map.get(obs_by_trace, content.trace_id)) || %{}
    trace_score = content.trace_id && Map.get(scores_by_trace, content.trace_id)

    %{
      "extracted_content_id" => content.id,
      "status" => content.status,
      "trace_id" => content.trace_id,
      "app_release" => trace_obs["app_release"],
      "processed_at" => format_datetime(content.inserted_at),
      "extraction" => build_run_extraction(content, ext_meta, trace_obs["extraction"]),
      "verification" =>
        build_run_verification(content.verification_status, verif, trace_obs["verification"]),
      "typesafe_shadow" => build_run_shadow(shadow),
      "langfuse_score" => trace_score
    }
  end

  defp build_run_extraction(%ExtractedContent{status: "failed"} = content, ext_meta, _obs) do
    %{
      "error_details" => content.error_details,
      "currency_hint" => ext_meta["currency_hint"]
    }
  end

  defp build_run_extraction(content, ext_meta, obs) do
    obs = obs || %{}

    %{
      "model" => ext_meta["extractor_model"] || obs["model"],
      "backend" => ext_meta["extractor_backend"],
      "prompt_name" => obs["prompt_name"] || "extract-invoice",
      "prompt_version" => ext_meta["prompt_version"] || obs["prompt_version"],
      "currency_hint" => ext_meta["currency_hint"],
      "output" => serialize_data(content.extracted_data),
      "usage" => obs["usage"],
      "cost" => obs["cost"],
      "latency_s" => obs["latency_s"]
    }
  end

  defp build_run_verification(nil, _verif, _obs), do: nil

  defp build_run_verification(status, verif, obs) do
    obs = obs || %{}

    %{
      "status" => status,
      "model" => verif["verifier_model"] || obs["model"],
      "prompt_name" => obs["prompt_name"] || "verify-extraction",
      "prompt_version" => verif["prompt_version"] || obs["prompt_version"],
      "reason" => verif["reason"],
      "field_issues" => parse_field_issues(verif["field_issues"]),
      "error" => verif["error"],
      "attempts" => verif["attempts"],
      "invalid_outputs" => verif["invalid_outputs"],
      "usage" => obs["usage"],
      "cost" => obs["cost"],
      "latency_s" => obs["latency_s"]
    }
  end

  defp build_run_shadow(nil), do: nil

  defp build_run_shadow(shadow) when is_map(shadow) do
    %{
      "status" => shadow["status"],
      "model" => shadow["model"],
      "review_threshold" => shadow["review_threshold"],
      "max_error_probability" => shadow["max_error_probability"],
      "field_probabilities" => shadow["field_probabilities"],
      "field_issues" => parse_field_issues(shadow["field_issues"]),
      "error" => shadow["error"],
      "usage" => shadow["usage"]
    }
  end

  defp parse_field_issues(nil), do: []
  defp parse_field_issues(""), do: []

  defp parse_field_issues(issues) when is_binary(issues) do
    issues
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.downcase(&1) == "none"))
  end

  defp parse_field_issues(issues) when is_list(issues), do: issues

  defp ocr_pages(%{"pages" => pages} = raw) when is_list(pages) do
    raw
    |> DocumentOCR.page_markdowns()
    |> Enum.with_index()
    |> Enum.map(fn {md, idx} -> %{"index" => idx, "markdown" => md} end)
  end

  defp ocr_pages(_raw), do: []

  defp ocr_model(content) do
    get_in(content.analysis || %{}, ["extraction", "ocr_model"]) ||
      Map.get(content.raw_llm_response || %{}, "model")
  end

  defp currency_hint(content, user_base_currency) do
    get_in(content.analysis || %{}, ["extraction", "currency_hint"]) || user_base_currency
  end

  defp file_matches_snapshot?(document, journal_entry) do
    current_sha = document.content_sha256
    snapshot_sha = journal_entry && journal_entry.source_document_sha256

    if is_binary(current_sha) and is_binary(snapshot_sha) do
      current_sha == snapshot_sha
    else
      nil
    end
  end

  defp serialize_data(nil), do: nil

  defp serialize_data(%ExtractedData{} = data) do
    %{
      "amount_to_pay_cents" => data.amount_to_pay_cents,
      "currency" => data.currency,
      "invoice_date" => data.invoice_date,
      "invoice_number" => data.invoice_number,
      "issuer" => data.issuer,
      "reason_for_payment" => data.reason_for_payment
    }
  end

  defp ground_truth_issuer(ground_truth, fallback_data) do
    get_in(ground_truth, ["extracted_faithful", "issuer"]) ||
      get_in(ground_truth, ["booked_values", "issuer"]) ||
      (fallback_data && fallback_data.issuer)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
end
