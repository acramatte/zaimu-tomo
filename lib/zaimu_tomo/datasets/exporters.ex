defmodule ZaimuTomo.Datasets.Exporters do
  @moduledoc """
  Derives task-specific JSONL datasets from a versioned `canonical.jsonl`:

    * `extractor_sft/{train,validation,test}.jsonl` — ChatML SFT examples for
      structured invoice extraction from OCR markdown + currency hint.
    * `verifier_sft/{train,validation,test}.jsonl` — ChatML SFT examples for
      extraction verification (positives, real historical mistakes, and
      split-isolated realistic synthetic negatives).
    * `vlm_sft/{train,validation,test}.jsonl` — multimodal ChatML examples
      referencing page image templates and S3 source keys (only for documents
      whose S3 bytes match the posting-time snapshot).
    * `eval/representative.jsonl` — held-out test-split benchmark records.
    * `eval/challenge.jsonl` — difficult/disagreed benchmark records across the
      dataset for targeted verifier, Jev, and extractor stress-testing.
    * `export_manifest.json` — counts and SHA-256 digests of every exported file.
  """

  alias ZaimuTomo.Datasets.Mutations
  alias ZaimuTomo.Fingerprint
  alias ZaimuTomo.Storage

  @splits ~w(train validation test)
  @invoice_fields ~w(amount_to_pay_cents currency invoice_date invoice_number issuer reason_for_payment)
  @version_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  @default_seed "zaimu-tomo-v1"

  @extractor_system_prompt """
  Extract structured invoice fields from OCR text as JSON with keys: \
  amount_to_pay_cents (integer cents, grand total incl. VAT; 0 or negative allowed), \
  currency (3-letter ISO 4217), invoice_date (YYYY-MM-DD), invoice_number (string or null), \
  issuer (string), reason_for_payment (short grounded phrase or null).\
  """

  @verifier_system_prompt """
  You are an extraction verification judge. Verify whether the extracted invoice JSON \
  is grounded in the source OCR markdown. Return JSON with keys: status \
  (verified, needs_review, or rejected), reason (concise explanation), and \
  field_issues (comma-separated field names or empty string).\
  """

  @vlm_system_prompt """
  Extract structured invoice fields directly from the invoice document image(s) as JSON \
  with keys: amount_to_pay_cents (integer cents, grand total incl. VAT), currency \
  (3-letter ISO 4217), invoice_date (YYYY-MM-DD), invoice_number (string or null), \
  issuer (string), reason_for_payment (short grounded phrase or null).\
  """

  @type summary :: %{
          input_source: String.t(),
          output_dir: String.t() | nil,
          s3_prefix: String.t() | nil,
          canonical_count: non_neg_integer(),
          counts: map(),
          manifest: map()
        }

  @doc """
  Reads `canonical.jsonl` from `:input` (local path) or from S3 (`from_s3: true`
  with `:version`) and writes all derived task datasets locally and/or to S3.

  ## Options

    * `:input` — local path to `canonical.jsonl` (required unless `from_s3: true`).
    * `:from_s3` — when `true`, reads `datasets/<version>/canonical.jsonl` via
      `ZaimuTomo.Storage.read_object/1` (requires `:version`, default `false`).
    * `:output_dir` — directory where `extractor_sft/`, `verifier_sft/`,
      `vlm_sft/`, `eval/`, and `export_manifest.json` are written. Defaults to
      `<dirname(input)>/exports` for local input; pass `nil` with
      `upload_s3: true` to upload directly to S3.
    * `:upload_s3` — when `true`, uploads exports under
      `datasets/<version>/exports/` (requires an explicit `:version`).
    * `:version` — explicit dataset version tag (`[a-zA-Z0-9][a-zA-Z0-9._-]*`),
      required whenever `:from_s3` or `:upload_s3` is `true`.
    * `:synthetic_negatives` — realistic synthetic negatives generated per
      eligible record in train/validation splits (default `2`).
    * `:synthetic_in_test` — whether to also generate synthetic negatives in
      `verifier_sft/test.jsonl` (default `false`).
    * `:seed` — deterministic seed for synthetic mutations (default
      `"zaimu-tomo-v1"`).
  """
  @spec export(keyword()) :: {:ok, summary()} | {:error, term()}
  def export(opts) when is_list(opts) do
    from_s3? = Keyword.get(opts, :from_s3, false)
    upload_s3? = Keyword.get(opts, :upload_s3, false)
    explicit_version = Keyword.get(opts, :version)

    with :ok <- validate_version_requirement(from_s3? or upload_s3?, explicit_version),
         {:ok, source_label, raw_canonical, records} <-
           load_source(from_s3?, explicit_version, opts),
         output_dir = resolve_output_dir(opts, from_s3?),
         :ok <- validate_destination(output_dir, upload_s3?) do
      version = explicit_version || infer_version(Keyword.get(opts, :input))
      input_sha256 = Fingerprint.sha256(raw_canonical)
      run_export(source_label, input_sha256, records, output_dir, upload_s3?, version, opts)
    end
  end

  @doc "Formats an export summary for CLI / release output."
  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    c = summary.counts

    lines = [
      "Exports built from #{summary.canonical_count} canonical records",
      "  extractor_sft: train=#{c["extractor_sft/train.jsonl"]} val=#{c["extractor_sft/validation.jsonl"]} test=#{c["extractor_sft/test.jsonl"]}",
      "  verifier_sft:  train=#{c["verifier_sft/train.jsonl"]} val=#{c["verifier_sft/validation.jsonl"]} test=#{c["verifier_sft/test.jsonl"]}",
      "  vlm_sft:       train=#{c["vlm_sft/train.jsonl"]} val=#{c["vlm_sft/validation.jsonl"]} test=#{c["vlm_sft/test.jsonl"]}",
      "  eval:          representative=#{c["eval/representative.jsonl"]} challenge=#{c["eval/challenge.jsonl"]}",
      if(summary.output_dir, do: "  local: #{summary.output_dir}"),
      if(summary.s3_prefix, do: "  s3: #{summary.s3_prefix}")
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  @doc "Derives Extractor SFT ChatML rows grouped by split."
  @spec build_extractor_sft([map()]) :: %{String.t() => [map()]}
  def build_extractor_sft(records) do
    records
    |> Enum.filter(&sft_ocr_eligible?/1)
    |> group_by_split(&extractor_sft_row/1)
  end

  @doc "Derives Verifier SFT ChatML rows grouped by split."
  @spec build_verifier_sft([map()], keyword()) :: %{String.t() => [map()]}
  def build_verifier_sft(records, opts \\ []) do
    synth_count = Keyword.get(opts, :synthetic_negatives, 2)
    synth_in_test? = Keyword.get(opts, :synthetic_in_test, false)
    seed = Keyword.get(opts, :seed, @default_seed)

    base = Map.new(@splits, &{&1, []})

    records
    |> Enum.filter(&sft_ocr_eligible?/1)
    |> Enum.reduce(base, fn record, acc ->
      split = record_split(record)
      count = if split == "test" and not synth_in_test?, do: 0, else: synth_count
      rows = verifier_rows_for_record(record, count, seed)
      Map.update(acc, split, Enum.reverse(rows), &Enum.reverse(rows, &1))
    end)
    |> Map.new(fn {split, rev_rows} -> {split, Enum.reverse(rev_rows)} end)
  end

  @doc "Derives Multimodal VLM SFT ChatML rows grouped by split."
  @spec build_vlm_sft([map()]) :: %{String.t() => [map()]}
  def build_vlm_sft(records) do
    records
    |> Enum.filter(&vlm_eligible?/1)
    |> group_by_split(&vlm_sft_row/1)
  end

  @doc """
  Derives held-out evaluation records from the `test` split:
  `representative` (all test-split reviewed records) and `challenge` (the
  challenge subset of the `test` split, preventing train/eval leakage).
  """
  @spec build_eval_sets([map()]) :: %{representative: [map()], challenge: [map()]}
  def build_eval_sets(records) do
    test_reviewed =
      records
      |> Enum.filter(&(eval_eligible?(&1) and record_split(&1) == "test"))

    %{
      representative: Enum.map(test_reviewed, &eval_row/1),
      challenge:
        test_reviewed
        |> Enum.filter(&get_in(&1, ["grouping", "challenge_eval"]))
        |> Enum.map(&eval_row/1)
    }
  end

  defp run_export(source_label, input_sha256, records, output_dir, upload_s3?, version, opts) do
    extractor = build_extractor_sft(records)
    verifier = build_verifier_sft(records, opts)
    vlm = build_vlm_sft(records)
    eval_sets = build_eval_sets(records)

    data_files =
      split_files("extractor_sft", extractor) ++
        split_files("verifier_sft", verifier) ++
        split_files("vlm_sft", vlm) ++
        [
          {"eval/representative.jsonl", eval_sets.representative},
          {"eval/challenge.jsonl", eval_sets.challenge}
        ]

    encoded = Enum.map(data_files, fn {rel, rows} -> {rel, length(rows), encode_jsonl(rows)} end)

    counts = Map.new(encoded, fn {rel, count, _body} -> {rel, count} end)
    sha256 = Map.new(encoded, fn {rel, _count, body} -> {rel, Fingerprint.sha256(body)} end)

    manifest = %{
      "version" => version,
      "exported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "input_sha256" => input_sha256,
      "canonical_count" => length(records),
      "synthetic_negatives" => Keyword.get(opts, :synthetic_negatives, 2),
      "synthetic_in_test" => Keyword.get(opts, :synthetic_in_test, false),
      "seed" => Keyword.get(opts, :seed, @default_seed),
      "counts" => counts,
      "sha256" => sha256
    }

    manifest_body = Jason.encode!(manifest, pretty: true) <> "\n"

    all_artifacts =
      Enum.map(encoded, fn {rel, _count, body} -> {rel, body} end) ++
        [{"export_manifest.json", manifest_body}]

    with {:ok, written_dir} <- maybe_write_local(output_dir, all_artifacts),
         {:ok, s3_prefix} <- maybe_upload_s3(upload_s3?, version, all_artifacts) do
      {:ok,
       %{
         input_source: source_label,
         output_dir: written_dir,
         s3_prefix: s3_prefix,
         canonical_count: length(records),
         counts: counts,
         manifest: manifest
       }}
    end
  end

  defp split_files(prefix, by_split) do
    Enum.map(@splits, fn split -> {"#{prefix}/#{split}.jsonl", Map.get(by_split, split, [])} end)
  end

  defp sft_ocr_eligible?(record) do
    has_ground_truth?(record) and
      non_blank?(get_in(record, ["inputs", "ocr", "markdown"])) and
      get_in(record, ["label", "ocr_faithful"]) != false
  end

  defp vlm_eligible?(record) do
    has_ground_truth?(record) and
      non_blank?(get_in(record, ["document", "s3_key"])) and
      get_in(record, ["document", "s3_exists"]) != false and
      get_in(record, ["document", "file_matches_posted_snapshot"]) != false
  end

  defp eval_eligible?(record) do
    has_ground_truth?(record) and non_blank?(get_in(record, ["inputs", "ocr", "markdown"]))
  end

  defp has_ground_truth?(record) do
    get_in(record, ["label", "review_status"]) in ["approved", "amended"] and
      is_map(get_in(record, ["ground_truth", "extracted_faithful"]))
  end

  defp group_by_split(records, mapper) do
    base = Map.new(@splits, &{&1, []})

    records
    |> Enum.reduce(base, fn record, acc ->
      split = record_split(record)
      row = mapper.(record)
      Map.update(acc, split, [row], &[row | &1])
    end)
    |> Map.new(fn {split, rev_rows} -> {split, Enum.reverse(rev_rows)} end)
  end

  defp extractor_sft_row(record) do
    gt = pick_invoice_fields(get_in(record, ["ground_truth", "extracted_faithful"]))
    hint = get_in(record, ["inputs", "currency_hint"]) || "CHF"
    markdown = get_in(record, ["inputs", "ocr", "markdown"])

    %{
      "messages" => [
        %{"role" => "system", "content" => @extractor_system_prompt},
        %{"role" => "user", "content" => "Currency hint: #{hint}\n\nOCR Text:\n#{markdown}"},
        %{"role" => "assistant", "content" => Jason.encode!(gt)}
      ],
      "meta" => %{
        "document_id" => record["document_id"],
        "split" => record_split(record),
        "label_quality" => get_in(record, ["label", "quality"])
      }
    }
  end

  defp verifier_rows_for_record(record, synth_count, seed) do
    gt = pick_invoice_fields(get_in(record, ["ground_truth", "extracted_faithful"]))
    markdown = get_in(record, ["inputs", "ocr", "markdown"])
    split = record_split(record)

    positive = [
      verifier_chat_row(
        markdown,
        gt,
        %{
          "status" => "verified",
          "reason" => "All extracted values are directly supported by the source OCR markdown.",
          "field_issues" => ""
        },
        %{
          "document_id" => record["document_id"],
          "split" => split,
          "synthetic" => false,
          "example_type" => "positive"
        }
      )
    ]

    real_negatives = real_verifier_negatives(record, gt, markdown, split)

    synthetic_negatives =
      gt
      |> Mutations.generate(record["document_id"], count: synth_count, seed: seed)
      |> Enum.map(fn m ->
        verifier_chat_row(
          markdown,
          m.candidate,
          %{
            "status" => m.expected_status,
            "reason" => m.reason,
            "field_issues" => Enum.join(m.field_issues, ",")
          },
          %{
            "document_id" => record["document_id"],
            "split" => split,
            "synthetic" => true,
            "example_type" => "synthetic_negative",
            "mutation" => m.mutation
          }
        )
      end)

    positive ++ real_negatives ++ synthetic_negatives
  end

  defp real_verifier_negatives(record, gt, markdown, split) do
    (record["processing_runs"] || [])
    |> Enum.filter(&(&1["status"] == "success"))
    |> Enum.map(&get_in(&1, ["extraction", "output"]))
    |> Enum.filter(&is_map/1)
    |> Enum.map(&pick_invoice_fields/1)
    |> Enum.uniq()
    |> Enum.reduce([], fn candidate, acc ->
      issues = diff_fields(candidate, gt)

      if issues == [] do
        acc
      else
        reason =
          "Extracted fields do not match the source OCR markdown: #{Enum.join(issues, ", ")}."

        row =
          verifier_chat_row(
            markdown,
            candidate,
            %{
              "status" => "rejected",
              "reason" => reason,
              "field_issues" => Enum.join(issues, ",")
            },
            %{
              "document_id" => record["document_id"],
              "split" => split,
              "synthetic" => false,
              "example_type" => "real_negative",
              "error_tags" => get_in(record, ["label", "error_tags"]) || []
            }
          )

        [row | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp verifier_chat_row(markdown, candidate, expected_output, meta) do
    user_content =
      "Extracted JSON:\n#{Jason.encode!(candidate)}\n\nSource OCR Markdown:\n#{markdown}"

    %{
      "messages" => [
        %{"role" => "system", "content" => @verifier_system_prompt},
        %{"role" => "user", "content" => user_content},
        %{"role" => "assistant", "content" => Jason.encode!(expected_output)}
      ],
      "meta" => meta
    }
  end

  defp vlm_sft_row(record) do
    gt = pick_invoice_fields(get_in(record, ["ground_truth", "extracted_faithful"]))
    hint = get_in(record, ["inputs", "currency_hint"]) || "CHF"
    page_count = max(get_in(record, ["document", "page_count"]) || 1, 1)
    doc_id = record["document_id"]

    image_parts =
      for idx <- 0..(page_count - 1) do
        %{"type" => "image", "image" => "images/doc_#{doc_id}_p#{idx}.png"}
      end

    text_part = %{
      "type" => "text",
      "text" => "Extract invoice fields as JSON. Currency hint: #{hint}."
    }

    %{
      "messages" => [
        %{"role" => "system", "content" => @vlm_system_prompt},
        %{"role" => "user", "content" => image_parts ++ [text_part]},
        %{"role" => "assistant", "content" => Jason.encode!(gt)}
      ],
      "meta" => %{
        "document_id" => doc_id,
        "split" => record_split(record),
        "s3_key" => get_in(record, ["document", "s3_key"]),
        "mime_type" => get_in(record, ["document", "mime_type"]),
        "page_count" => page_count
      }
    }
  end

  defp eval_row(record) do
    gt = pick_invoice_fields(get_in(record, ["ground_truth", "extracted_faithful"]))
    latest_run = latest_success_run(record)
    candidate = latest_run && pick_invoice_fields(get_in(latest_run, ["extraction", "output"]))
    issues = if is_map(candidate), do: diff_fields(candidate, gt), else: []

    %{
      "document_id" => record["document_id"],
      "extracted_content_id" => latest_run && latest_run["extracted_content_id"],
      "trace_id" => latest_run && latest_run["trace_id"],
      "split" => record_split(record),
      "challenge_eval" => get_in(record, ["grouping", "challenge_eval"]) == true,
      "currency_hint" => get_in(record, ["inputs", "currency_hint"]),
      "ocr_markdown" => get_in(record, ["inputs", "ocr", "markdown"]),
      "s3_key" => get_in(record, ["document", "s3_key"]),
      "ground_truth" => gt,
      "candidate_extraction" => candidate,
      "expected_verdict" => if(issues == [], do: "verified", else: "rejected"),
      "expected_field_issues" => issues,
      "label_quality" => get_in(record, ["label", "quality"]),
      "human_thumbs" => get_in(record, ["label", "human_thumbs"]),
      "ocr_faithful" => get_in(record, ["label", "ocr_faithful"]),
      "error_tags" => get_in(record, ["label", "error_tags"]) || [],
      "baseline_verifier" => latest_run && latest_run["verification"],
      "baseline_jev" => latest_run && latest_run["typesafe_shadow"]
    }
  end

  defp latest_success_run(record) do
    (record["processing_runs"] || [])
    |> Enum.filter(&(&1["status"] == "success"))
    |> List.last()
  end

  defp diff_fields(candidate, ground_truth) do
    Enum.filter(@invoice_fields, fn field ->
      comparable(Map.get(candidate, field)) != comparable(Map.get(ground_truth, field))
    end)
  end

  defp comparable(val) when is_binary(val), do: String.trim(val)
  defp comparable(val), do: val

  defp pick_invoice_fields(map) when is_map(map), do: Map.take(map, @invoice_fields)
  defp pick_invoice_fields(_other), do: nil

  defp record_split(record) do
    case get_in(record, ["grouping", "split"]) do
      split when split in @splits -> split
      _other -> "train"
    end
  end

  defp non_blank?(val) when is_binary(val), do: String.trim(val) != ""
  defp non_blank?(_other), do: false

  defp encode_jsonl([]), do: ""
  defp encode_jsonl(rows), do: Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n"

  defp load_source(true, version, _opts) do
    key = "datasets/#{version}/canonical.jsonl"

    with {:ok, raw} <- Storage.read_object(key),
         {:ok, records} <- decode_jsonl(raw) do
      {:ok, "s3://#{key}", raw, records}
    else
      {:error, {:invalid_canonical_jsonl, _}} = err -> err
      {:error, reason} -> {:error, {:s3_canonical_read_failed, key, reason}}
    end
  end

  defp load_source(false, _version, opts) do
    with {:ok, input_path} <- fetch_input(opts),
         {:ok, raw} <- read_local_canonical(input_path),
         {:ok, records} <- decode_jsonl(raw) do
      {:ok, input_path, raw, records}
    end
  end

  defp fetch_input(opts) do
    case Keyword.get(opts, :input) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _other -> {:error, :missing_input}
    end
  end

  defp read_local_canonical(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:canonical_read_failed, path, reason}}
    end
  end

  defp decode_jsonl(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &decode_jsonl_line/2)
    |> case do
      {:ok, rev_rows} -> {:ok, Enum.reverse(rev_rows)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_jsonl_line({line, line_no}, {:ok, acc}) do
    case String.trim(line) do
      "" -> {:cont, {:ok, acc}}
      trimmed -> parse_jsonl_object(trimmed, line_no, acc)
    end
  end

  defp parse_jsonl_object(line, line_no, acc) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:cont, {:ok, [map | acc]}}
      _other -> {:halt, {:error, {:invalid_canonical_jsonl, line_no}}}
    end
  end

  defp resolve_output_dir(opts, true), do: Keyword.get(opts, :output_dir)

  defp resolve_output_dir(opts, false) do
    case Keyword.fetch(opts, :output_dir) do
      {:ok, dir} -> dir
      :error -> default_output_dir(Keyword.fetch!(opts, :input))
    end
  end

  defp default_output_dir(input_path), do: Path.join(Path.dirname(input_path), "exports")

  defp infer_version(input_path) when is_binary(input_path),
    do: input_path |> Path.dirname() |> Path.basename()

  defp infer_version(_other), do: nil

  defp validate_version_requirement(false, nil), do: :ok

  defp validate_version_requirement(_required?, version) when is_binary(version) do
    if Regex.match?(@version_regex, version),
      do: :ok,
      else: {:error, {:invalid_version, version}}
  end

  defp validate_version_requirement(true, _other), do: {:error, :missing_version}

  defp validate_destination(nil, false), do: {:error, :no_output_destination}
  defp validate_destination(_output_dir, _upload_s3?), do: :ok

  defp maybe_write_local(nil, _artifacts), do: {:ok, nil}

  defp maybe_write_local(output_dir, artifacts) do
    case write_local_artifacts(output_dir, artifacts) do
      :ok -> {:ok, output_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_local_artifacts(output_dir, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn {rel, body}, :ok ->
      full_path = Path.join(output_dir, rel)

      with :ok <- File.mkdir_p(Path.dirname(full_path)),
           :ok <- File.write(full_path, body) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:write_failed, rel, reason}}}
      end
    end)
  end

  defp maybe_upload_s3(false, _version, _artifacts), do: {:ok, nil}

  defp maybe_upload_s3(true, version, artifacts) do
    prefix = "datasets/#{version}/exports"

    Enum.reduce_while(artifacts, {:ok, prefix}, fn {rel, body}, {:ok, ^prefix} ->
      key = "#{prefix}/#{rel}"

      case Storage.put_object(key, body) do
        {:ok, _key} -> {:cont, {:ok, prefix}}
        {:error, reason} -> {:halt, {:error, {:s3_upload_failed, key, reason}}}
      end
    end)
  end
end
