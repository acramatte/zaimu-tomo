defmodule Mix.Tasks.ZaimuTomo.Dataset.Export do
  @moduledoc """
  Derives task-specific JSONL datasets (`extractor_sft`, `verifier_sft`,
  `vlm_sft`, and `eval/{representative,challenge}`) from a `canonical.jsonl`.

      mix zaimu_tomo.dataset.export --input tmp/datasets/v001/canonical.jsonl
      mix zaimu_tomo.dataset.export --input tmp/datasets/v001/canonical.jsonl --upload-s3 --version v001
      mix zaimu_tomo.dataset.export --from-s3 --version v001 --upload-s3

  ## Options

    * `--input` — local path to `canonical.jsonl` (required unless `--from-s3`).
    * `--from-s3` — read `datasets/<version>/canonical.jsonl` from object storage.
    * `--output-dir` — destination directory (defaults to `<dirname(input)>/exports` for local input).
    * `--upload-s3` — also upload exported files under `datasets/<version>/exports/` (requires `--version`).
    * `--version` — dataset version tag (required with `--from-s3` or `--upload-s3`).
    * `--synthetic-negatives` — realistic synthetic negatives per record (default `2`).
    * `--synthetic-in-test` — also generate synthetic negatives in `verifier_sft/test.jsonl`.
    * `--seed` — deterministic mutation seed (default `zaimu-tomo-v1`).
  """
  @shortdoc "Derives SFT, VLM, and evaluation JSONL datasets from canonical.jsonl"

  use Mix.Task

  alias ZaimuTomo.Release

  @usage """
  usage: mix zaimu_tomo.dataset.export (--input PATH | --from-s3 --version VERSION) \
  [--output-dir DIR] [--upload-s3] [--version VERSION] \
  [--synthetic-negatives N] [--synthetic-in-test] [--seed SEED]
  """

  @switches [
    input: :string,
    from_s3: :boolean,
    output_dir: :string,
    upload_s3: :boolean,
    version: :string,
    synthetic_negatives: :integer,
    synthetic_in_test: :boolean,
    seed: :string
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :input) || Keyword.get(opts, :from_s3) do
          Release.export_dataset!(opts)
        else
          Mix.raise(@usage)
        end

      _ ->
        Mix.raise(@usage)
    end
  end
end
