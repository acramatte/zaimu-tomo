defmodule Mix.Tasks.ZaimuTomo.Dataset.PublishLangfuse do
  @moduledoc """
  Publishes an exported evaluation JSONL (`eval/representative.jsonl` or
  `eval/challenge.jsonl`) into a Langfuse Dataset with deterministic item IDs.

      mix zaimu_tomo.dataset.publish_langfuse \\
        --input tmp/datasets/v001/exports/eval/challenge.jsonl \\
        --dataset invoice-extraction-challenge-v001 \\
        --task extraction

  ## Options

    * `--input` — local path to an exported `eval/*.jsonl` file (required unless
      `--s3-key` is given).
    * `--s3-key` — S3 key of an exported `eval/*.jsonl` object (required unless
      `--input` is given).
    * `--dataset` (required) — Langfuse dataset name.
    * `--task` — `extraction` (default) or `verification`.
    * `--description` — optional dataset description.
    * `--dry-run` — validate inputs without making HTTP requests.
  """
  @shortdoc "Publishes an exported evaluation JSONL into Langfuse Datasets"

  use Mix.Task

  alias ZaimuTomo.Release

  @usage """
  usage: mix zaimu_tomo.dataset.publish_langfuse (--input PATH | --s3-key KEY) --dataset NAME \
  [--task extraction|verification] [--description TEXT] [--dry-run]
  """

  @switches [
    input: :string,
    s3_key: :string,
    dataset: :string,
    task: :string,
    description: :string,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        has_source? =
          is_binary(Keyword.get(opts, :input)) or is_binary(Keyword.get(opts, :s3_key))

        if has_source? and is_binary(Keyword.get(opts, :dataset)) do
          Release.publish_dataset_to_langfuse!(opts)
        else
          Mix.raise(@usage)
        end

      _ ->
        Mix.raise(@usage)
    end
  end
end
