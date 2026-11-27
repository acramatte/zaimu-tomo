defmodule ZaimuTomo.Datasets.Builder do
  @moduledoc """
  Builds a versioned, model-agnostic canonical invoice dataset from PostgreSQL,
  object storage, optional Langfuse enrichment, and an optional human audit
  overlay.

  This is intentionally unscoped (like `ZaimuTomo.Storage.Verification` and
  `ZaimuTomo.Documents.FingerprintBackfill`), with an optional `:user_id` filter
  for single-user exports.

  Outputs under `<output_dir>/<version>/` (and optionally `datasets/<version>/`
  in object storage):

    * `canonical.jsonl` — one schema-v1 canonical invoice record per line,
      sorted by `document_id`.
    * `splits.json` — deterministic issuer/fingerprint-grouped train/val/test
      assignments.
    * `manifest.json` — dataset metadata, counts, warnings, and artifact SHA-256
      digests.
  """

  import Ecto.Query, only: [from: 2]

  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.Datasets.{AuditOverlay, LangfuseReader, Record, Splits}
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.{Fingerprint, Repo, Storage}

  @version_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  @default_output_dir "tmp/datasets"
  @default_seed "zaimu-tomo-v1"

  @type summary :: %{
          version: String.t(),
          output_dir: String.t() | nil,
          s3_prefix: String.t() | nil,
          record_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          split_counts: map(),
          label_quality_counts: map(),
          review_status_counts: map(),
          storage_missing_count: non_neg_integer(),
          file_mismatch_count: non_neg_integer(),
          langfuse_enriched: boolean(),
          warnings: [String.t()],
          manifest: map()
        }

  @doc """
  Builds the canonical dataset version and writes its artifacts locally and/or
  to object storage.

  ## Options

    * `:version` (required) — version tag such as `"v001"`.
    * `:output_dir` — base directory for local output (default `"tmp/datasets"`).
      Pass `nil` with `upload_s3: true` to upload directly without writing local
      files.
    * `:upload_s3` — when `true`, uploads artifacts under `datasets/<version>/`
      via `ZaimuTomo.Storage.put_object/2` (default `false`).
    * `:verify_storage` — when `true`, HEADs each document's S3 object key to
      populate `document.s3_exists` (default `true`).
    * `:enrich_langfuse` — when `true`, fetches Langfuse v3 scores and v2
      observations (default `false`).
    * `:langfuse_opts` — optional overrides passed to `LangfuseReader` (useful
      in tests).
    * `:audit_overlay` — optional path to an `audit_overlay.jsonl` file.
    * `:user_id` — optional user ID filter.
    * `:include_pending` — include pending-review documents (default `false`).
    * `:overwrite` — allow overwriting an existing local or S3 version
      directory (default `false`).
    * `:seed` — split seed string (default `"zaimu-tomo-v1"`).
  """
  @spec build(keyword()) :: {:ok, summary()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with {:ok, version} <- validate_version(Keyword.get(opts, :version)),
         {:ok, overlay} <- AuditOverlay.load(Keyword.get(opts, :audit_overlay)),
         output_dir = Keyword.get(opts, :output_dir, @default_output_dir),
         upload_s3? = Keyword.get(opts, :upload_s3, false),
         overwrite? = Keyword.get(opts, :overwrite, false),
         :ok <- validate_destination(output_dir, upload_s3?),
         :ok <- check_not_existing(overwrite?, output_dir, upload_s3?, version) do
      run_build(version, overlay, output_dir, upload_s3?, opts)
    end
  end

  @doc "Formats a build summary for CLI / release output."
  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    lines = [
      "Dataset #{summary.version} built (#{summary.record_count} records, #{summary.skipped_count} skipped)",
      "  splits: train=#{summary.split_counts["train"]} validation=#{summary.split_counts["validation"]} test=#{summary.split_counts["test"]}",
      "  storage missing: #{summary.storage_missing_count}, file snapshot mismatches: #{summary.file_mismatch_count}",
      if(summary.output_dir, do: "  local: #{summary.output_dir}"),
      if(summary.s3_prefix, do: "  s3: #{summary.s3_prefix}"),
      if(summary.warnings != [], do: "  warnings: #{length(summary.warnings)}")
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp run_build(version, overlay, output_dir, upload_s3?, opts) do
    documents = load_documents(Keyword.get(opts, :user_id))
    user_currencies = load_user_currencies(documents)

    enrich? = Keyword.get(opts, :enrich_langfuse, false)
    langfuse = maybe_enrich_langfuse(enrich?, documents, Keyword.get(opts, :langfuse_opts, []))

    verify_storage? = Keyword.get(opts, :verify_storage, true)
    include_pending? = Keyword.get(opts, :include_pending, false)

    {records, skipped_count, storage_warnings} =
      assemble_records(documents, %{
        user_currencies: user_currencies,
        audit_overlay: overlay,
        langfuse: langfuse,
        verify_storage?: verify_storage?,
        include_pending?: include_pending?
      })

    warnings = langfuse.warnings ++ storage_warnings
    langfuse_enriched? = enrich? and langfuse.configured?

    seed = Keyword.get(opts, :seed, @default_seed)
    {records, splits_artifact} = Splits.assign(records, seed: seed, version: version)

    canonical_body = encode_jsonl(records)
    splits_body = Jason.encode!(splits_artifact, pretty: true) <> "\n"

    manifest =
      build_manifest(
        version,
        records,
        skipped_count,
        splits_artifact,
        canonical_body,
        splits_body,
        langfuse_enriched?,
        warnings
      )

    manifest_body = Jason.encode!(manifest, pretty: true) <> "\n"

    artifacts = [
      {"canonical.jsonl", canonical_body},
      {"splits.json", splits_body},
      {"manifest.json", manifest_body}
    ]

    with {:ok, written_dir} <- maybe_write_local(output_dir, version, artifacts),
         {:ok, s3_prefix} <- maybe_upload_s3(upload_s3?, version, artifacts) do
      {:ok,
       %{
         version: version,
         output_dir: written_dir,
         s3_prefix: s3_prefix,
         record_count: length(records),
         skipped_count: skipped_count,
         split_counts: manifest["split_counts"],
         label_quality_counts: manifest["label_quality_counts"],
         review_status_counts: manifest["review_status_counts"],
         storage_missing_count: manifest["storage_missing_count"],
         file_mismatch_count: manifest["file_mismatch_count"],
         langfuse_enriched: langfuse_enriched?,
         warnings: warnings,
         manifest: manifest
       }}
    end
  end

  defp load_documents(user_id) do
    ec_query =
      from ec in ExtractedContent,
        order_by: [asc: ec.inserted_at, asc: ec.id],
        preload: [review_decision: :journal_entry]

    base =
      from d in Document,
        order_by: [asc: d.id],
        preload: [extracted_content: ^ec_query]

    query =
      if is_integer(user_id),
        do: from(d in base, where: d.user_id == ^user_id),
        else: base

    Repo.all(query)
  end

  defp load_user_currencies(documents) do
    user_ids = documents |> Enum.map(& &1.user_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

    if user_ids == [] do
      %{}
    else
      from(u in User, where: u.id in ^user_ids, select: {u.id, u.base_currency})
      |> Repo.all()
      |> Map.new()
    end
  end

  defp maybe_enrich_langfuse(false, _documents, _opts), do: LangfuseReader.empty()

  defp maybe_enrich_langfuse(true, documents, langfuse_opts) do
    trace_ids =
      for doc <- documents,
          ec <- doc.extracted_content || [],
          is_binary(ec.trace_id) and ec.trace_id != "",
          do: ec.trace_id

    LangfuseReader.fetch_enrichment(trace_ids, langfuse_opts)
  end

  defp assemble_records(documents, ctx) do
    eligibility = %{include_pending: ctx.include_pending?}

    {rev_records, skipped, rev_warnings} =
      Enum.reduce(documents, {[], 0, []}, fn doc, {acc, skipped, warnings} ->
        if Record.eligible?(doc, eligibility) do
          build_eligible_record(doc, ctx, acc, skipped, warnings)
        else
          {acc, skipped + 1, warnings}
        end
      end)

    {Enum.reverse(rev_records), skipped, Enum.reverse(rev_warnings)}
  end

  defp build_eligible_record(doc, ctx, acc, skipped, warnings) do
    {s3_exists, head_warnings} = check_storage(ctx.verify_storage?, doc)

    record_ctx = %{
      user_base_currency: Map.get(ctx.user_currencies, doc.user_id),
      s3_exists: s3_exists,
      audit_overlay: ctx.audit_overlay,
      scores_by_trace: ctx.langfuse.scores_by_trace,
      observations_by_trace: ctx.langfuse.observations_by_trace,
      include_pending: ctx.include_pending?
    }

    case Record.build(doc, record_ctx) do
      {:ok, record} -> {[record | acc], skipped, head_warnings ++ warnings}
      :skip -> {acc, skipped + 1, head_warnings ++ warnings}
    end
  end

  defp check_storage(false, _doc), do: {nil, []}

  defp check_storage(true, %Document{id: id, object_key: object_key})
       when is_binary(object_key) do
    case Storage.head_object(object_key) do
      :ok -> {true, []}
      {:error, :not_found} -> {false, []}
      {:error, reason} -> {nil, ["storage HEAD failed for document #{id}: #{inspect(reason)}"]}
    end
  end

  defp check_storage(true, _doc), do: {false, []}

  defp encode_jsonl([]), do: ""

  defp encode_jsonl(records) do
    Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
  end

  defp build_manifest(
         version,
         records,
         skipped_count,
         splits_artifact,
         canonical_body,
         splits_body,
         enrich?,
         warnings
       ) do
    %{
      "dataset_schema_version" => Record.schema_version(),
      "version" => version,
      "built_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "app_version" => app_version(),
      "record_count" => length(records),
      "skipped_count" => skipped_count,
      "split_counts" => splits_artifact["split_counts"],
      "challenge_eval_count" => splits_artifact["challenge_eval_count"],
      "label_quality_counts" => count_frequencies(records, &get_in(&1, ["label", "quality"])),
      "review_status_counts" =>
        count_frequencies(records, &get_in(&1, ["label", "review_status"])),
      "storage_missing_count" =>
        Enum.count(records, &(get_in(&1, ["document", "s3_exists"]) == false)),
      "file_mismatch_count" =>
        Enum.count(
          records,
          &(get_in(&1, ["document", "file_matches_posted_snapshot"]) == false)
        ),
      "langfuse_enriched" => enrich?,
      "warnings" => warnings,
      "sha256" => %{
        "canonical.jsonl" => Fingerprint.sha256(canonical_body),
        "splits.json" => Fingerprint.sha256(splits_body)
      }
    }
  end

  defp count_frequencies(records, fun) do
    records |> Enum.map(fun) |> Enum.frequencies()
  end

  defp maybe_write_local(nil, _version, _artifacts), do: {:ok, nil}

  defp maybe_write_local(output_dir, version, artifacts) do
    version_dir = Path.join(output_dir, version)

    with :ok <- File.mkdir_p(version_dir),
         :ok <- write_files(version_dir, artifacts) do
      {:ok, version_dir}
    end
  end

  defp write_files(dir, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn {filename, body}, :ok ->
      case File.write(Path.join(dir, filename), body) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, filename, reason}}}
      end
    end)
  end

  defp maybe_upload_s3(false, _version, _artifacts), do: {:ok, nil}

  defp maybe_upload_s3(true, version, artifacts) do
    prefix = "datasets/#{version}"

    Enum.reduce_while(artifacts, {:ok, prefix}, fn {filename, body}, {:ok, ^prefix} ->
      key = "#{prefix}/#{filename}"

      case Storage.put_object(key, body) do
        {:ok, _key} -> {:cont, {:ok, prefix}}
        {:error, reason} -> {:halt, {:error, {:s3_upload_failed, key, reason}}}
      end
    end)
  end

  defp validate_version(version) when is_binary(version) do
    if Regex.match?(@version_regex, version),
      do: {:ok, version},
      else: {:error, {:invalid_version, version}}
  end

  defp validate_version(_other), do: {:error, :missing_version}

  defp validate_destination(nil, false), do: {:error, :no_output_destination}
  defp validate_destination(_output_dir, _upload_s3?), do: :ok

  defp check_not_existing(true, _output_dir, _upload_s3?, _version), do: :ok

  defp check_not_existing(false, output_dir, upload_s3?, version) do
    local_exists? =
      is_binary(output_dir) and File.exists?(Path.join([output_dir, version, "manifest.json"]))

    s3_exists? = upload_s3? and Storage.head_object("datasets/#{version}/manifest.json") == :ok

    if local_exists? or s3_exists? do
      {:error, {:version_already_exists, version}}
    else
      :ok
    end
  end

  defp app_version do
    case Application.spec(:zaimu_tomo, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
