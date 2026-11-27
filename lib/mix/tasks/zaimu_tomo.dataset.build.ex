defmodule Mix.Tasks.ZaimuTomo.Dataset.Build do
  @moduledoc """
  Builds a versioned canonical invoice dataset (`canonical.jsonl`, `splits.json`,
  `manifest.json`) from PostgreSQL, object storage, and optional Langfuse
  enrichment.

      mix zaimu_tomo.dataset.build --version v001
      mix zaimu_tomo.dataset.build --version v001 --output-dir tmp/datasets --enrich-langfuse
      mix zaimu_tomo.dataset.build --version v001 --upload-s3 --audit-overlay audit_overlay.jsonl

  ## Options

    * `--version` (required) — version tag such as `v001`.
    * `--output-dir` — local output root (default `tmp/datasets`).
    * `--upload-s3` — also upload artifacts under `datasets/<version>/` in S3.
    * `--enrich-langfuse` — enrich runs with Langfuse v3 scores and v2 observations.
    * `--no-verify-storage` — skip `HEAD` existence checks on S3 object keys.
    * `--audit-overlay` — path to an optional `audit_overlay.jsonl` file.
    * `--user-id` — restrict the export to a single user ID.
    * `--include-pending` — include documents whose review is still pending.
    * `--overwrite` — allow overwriting an existing dataset version.
    * `--seed` — deterministic split seed (default `zaimu-tomo-v1`).
  """
  @shortdoc "Builds a versioned canonical invoice dataset"

  use Mix.Task

  alias ZaimuTomo.Release

  @usage """
  usage: mix zaimu_tomo.dataset.build --version VERSION [--output-dir DIR] \
  [--upload-s3] [--enrich-langfuse] [--no-verify-storage] \
  [--audit-overlay PATH] [--user-id ID] [--include-pending] [--overwrite] [--seed SEED]
  """

  @switches [
    version: :string,
    output_dir: :string,
    upload_s3: :boolean,
    enrich_langfuse: :boolean,
    verify_storage: :boolean,
    audit_overlay: :string,
    user_id: :integer,
    include_pending: :boolean,
    overwrite: :boolean,
    seed: :string
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :version) do
          Release.build_dataset!(opts)
        else
          Mix.raise(@usage)
        end

      _ ->
        Mix.raise(@usage)
    end
  end
end
