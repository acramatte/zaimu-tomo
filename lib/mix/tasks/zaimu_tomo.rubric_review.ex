defmodule Mix.Tasks.ZaimuTomo.RubricReview do
  @moduledoc """
  Validates `.rubrics/*.yaml` definitions and optionally runs the advisory LLM
  rubric critic against a git diff.

      mix zaimu_tomo.rubric_review --validate-only
      mix zaimu_tomo.rubric_review --base origin/main --head HEAD --dry-run
      mix zaimu_tomo.rubric_review --base origin/main --head HEAD --output-md /tmp/review.md

  ## Options

    * `--rubrics-dir` — directory containing `*.yaml` rubrics (default `.rubrics`).
    * `--repo-root` — git repository root (default `.`).
    * `--base` — git base ref for diff (default `origin/main`).
    * `--head` — git head ref for diff (default `HEAD`).
    * `--task-rubric` — optional path to a pre-code task rubric YAML.
    * `--pr-body-file` — optional markdown file to inspect for a fenced
      `yaml rubric` block.
    * `--logs-file` — optional raw CI verification logs to include for the critic.
    * `--max-diff-chars` — max unified diff characters sent to the critic
      (default `120000`).
    * `--validate-only` — validate all rubric YAML files and exit.
    * `--dry-run` — match rubrics and print JSON summary without calling the LLM.
    * `--render-prompt` — write the assembled critic prompt markdown to a file.
    * `--output-json` — write structured JSON scoring result to a file.
    * `--output-md` — write rendered Markdown PR comment to a file.
    * `--min-score` — exit with error if final score is below this float threshold.
  """
  @shortdoc "Validates PR rubrics and runs the advisory LLM rubric critic"

  use Mix.Task

  alias ZaimuTomo.Rubrics

  @switches [
    rubrics_dir: :string,
    repo_root: :string,
    base: :string,
    head: :string,
    task_rubric: :string,
    pr_body_file: :string,
    logs_file: :string,
    max_diff_chars: :integer,
    validate_only: :boolean,
    dry_run: :boolean,
    render_prompt: :string,
    output_json: :string,
    output_md: :string,
    min_score: :float
  ]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        maybe_start_req(opts)
        handle_result(Rubrics.run(opts), opts)

      {_opts, _rest, invalid} ->
        Mix.raise("Invalid arguments for zaimu_tomo.rubric_review: #{inspect(invalid)}")
    end
  end

  defp maybe_start_req(opts) do
    unless Keyword.get(opts, :validate_only, false) or Keyword.get(opts, :dry_run, false) do
      {:ok, _} = Application.ensure_all_started(:req)
    end
  end

  defp handle_result({:ok, %{mode: :validate_only, count: count}}, _opts) do
    Mix.shell().info("Validated #{count} rubric file(s): OK")
  end

  defp handle_result({:ok, %{mode: :skipped, reason: reason}}, _opts) do
    Mix.shell().info("Rubric review skipped (#{reason}).")
  end

  defp handle_result({:ok, %{mode: :dry_run} = summary}, _opts) do
    payload = Map.delete(summary, :mode)
    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp handle_result({:ok, %{mode: :live, result: result, markdown: markdown}}, opts) do
    unless is_binary(opts[:output_md]) and opts[:output_md] != "" do
      Mix.shell().info(markdown)
    end

    min_score = Keyword.get(opts, :min_score, 0.0)

    if min_score > 0.0 and result.final_score < min_score do
      Mix.raise("Rubric score #{Float.round(result.final_score, 2)} below threshold #{min_score}")
    end
  end

  defp handle_result({:error, {:validation_failed, errors}}, _opts) do
    Mix.raise("Rubric validation failed:\n" <> Enum.map_join(errors, "\n", &"  - #{&1}"))
  end

  defp handle_result({:error, reason}, _opts) do
    Mix.raise("Rubric review failed: #{inspect(reason)}")
  end
end
