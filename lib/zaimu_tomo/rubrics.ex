defmodule ZaimuTomo.Rubrics do
  @moduledoc """
  Path-matched PR review rubric validator, selector, and advisory LLM critic
  runner.

  Supports two layers of rubrics:
  1. Static path-matched repo rubrics in `.rubrics/*.yaml`
  2. Optional pre-code task rubric via `:task_rubric` or a fenced
     `yaml rubric` block in the PR body (`:pr_body_file`).

  Scores and subtractive penalties are computed deterministically in Elixir
  from the critic's structured JSON response.
  """

  alias ZaimuTomo.Rubrics.Yaml

  @comment_marker "<!-- zaimu-tomo-rubric-review -->"
  @valid_scores [0.0, 0.5, 1.0]
  @valid_statuses ~w(pass partial fail not_applicable)
  @excluded_diff_paths [":!mix.lock", ":!assets/package-lock.json"]
  @default_max_diff_chars 120_000
  @default_base_url "https://generativelanguage.googleapis.com/v1beta/openai"
  @default_model "gemini-4-carbon"

  @doc "HTML marker used to locate and update the sticky PR comment."
  @spec comment_marker() :: String.t()
  def comment_marker, do: @comment_marker

  @doc "Loads all `*.yaml` rubric files from `rubrics_dir`, sorted by path."
  @spec load_dir(Path.t()) :: [{Path.t(), map()}]
  def load_dir(rubrics_dir) when is_binary(rubrics_dir) do
    rubrics_dir
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path -> {path, path |> File.read!() |> Yaml.parse()} end)
  end

  @doc "Validates a parsed rubric map and returns a list of error strings."
  @spec validate(map(), String.t()) :: [String.t()]
  def validate(rubric, source) when is_map(rubric) and is_binary(source) do
    []
    |> check_name(rubric, source)
    |> check_paths(rubric, source)
    |> check_criteria(rubric, source)
    |> check_penalties(rubric, source)
    |> Enum.reverse()
  end

  def validate(_other, source), do: ["#{source}: root must be a YAML mapping"]

  @doc "Extracts an optional fenced `yaml rubric` block from a PR description."
  @spec extract_from_pr_body(String.t()) :: map() | nil
  def extract_from_pr_body(body) when is_binary(body) do
    case Regex.run(~r/```yaml\s+rubric\s*\r?\n(.*?)\r?\n```/si, body) do
      [_full, yaml_text] ->
        parsed = Yaml.parse(yaml_text)

        if map_size(parsed) > 0 do
          Map.put_new(parsed, "name", "pr_task_rubric")
        end

      _ ->
        nil
    end
  end

  @doc "Returns `true` if `path` matches any git-style glob pattern (supports `**`)."
  @spec path_matches_any?(String.t(), [String.t()]) :: boolean()
  def path_matches_any?(path, patterns) when is_binary(path) and is_list(patterns) do
    normalized = String.trim_leading(path, "./")
    Enum.any?(patterns, &Regex.match?(glob_to_regex(&1), normalized))
  end

  @doc "Translates a git-style path glob (including `**`) into a compiled Regex."
  @spec glob_to_regex(String.t()) :: Regex.t()
  def glob_to_regex(pattern) when is_binary(pattern) do
    source =
      pattern
      |> String.trim_leading("./")
      |> translate_glob("")

    Regex.compile!("\\A" <> source <> "\\z")
  end

  @doc """
  Selects repo rubrics whose `paths` match `changed_files`, merges an optional
  task rubric, and normalizes criterion weights to sum to `1.0`.
  """
  @spec select_and_merge([{Path.t(), map()}], [String.t()], map() | nil) :: map()
  def select_and_merge(repo_rubrics, changed_files, task_rubric \\ nil) do
    matching =
      repo_rubrics
      |> Enum.map(fn {_path, rubric} -> rubric end)
      |> Enum.filter(&rubric_matches?(&1, changed_files))

    active = if task_rubric, do: matching ++ [task_rubric], else: matching

    {matched_names, criteria_order, criteria_map, penalty_order, penalty_map} =
      Enum.reduce(active, {[], [], %{}, [], %{}}, &merge_rubric/2)

    criteria =
      criteria_order
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(criteria_map, &1))
      |> normalize_weights()

    penalties =
      penalty_order
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(penalty_map, &1))

    %{
      matched_rubrics: Enum.reverse(matched_names),
      criteria: criteria,
      penalties: penalties
    }
  end

  @doc "Collects changed file paths, `git diff --stat`, and bounded unified diff."
  @spec collect_git_context(Path.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, %{changed_files: [String.t()], diff_stat: String.t(), diff_body: String.t()}}
          | {:error, term()}
  def collect_git_context(repo_root, base, head, max_diff_chars \\ @default_max_diff_chars) do
    range = "#{base}...#{head}"

    with {:ok, names_raw} <- git_cmd(["diff", "--name-only", range], repo_root),
         {:ok, stat_raw} <- git_cmd(["diff", "--stat", range], repo_root),
         {:ok, diff_raw} <-
           git_cmd(["diff", "--unified=3", range, "--", "." | @excluded_diff_paths], repo_root) do
      changed_files =
        names_raw
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok,
       %{
         changed_files: changed_files,
         diff_stat: String.trim(stat_raw),
         diff_body: truncate_diff(diff_raw, max_diff_chars)
       }}
    end
  end

  @doc "Builds `[system, user]` chat messages for the LLM rubric critic."
  @spec build_critic_messages(map(), [String.t()], String.t(), String.t(), String.t()) :: [map()]
  def build_critic_messages(merged, changed_files, diff_stat, diff_body, raw_logs \\ "") do
    system_prompt =
      "You are an independent, strict staff code reviewer grading a pull request " <>
        "against a task-specific rubric. Grade like a reviewer, not a unit test: " <>
        "reward genuine correctness, penalize brittle workarounds or invariant " <>
        "violations, and NEVER hallucinate file paths or line numbers. " <>
        "Every deduction (score < 1.0) or triggered penalty MUST cite exact file:line " <>
        "or log evidence from the provided diff/logs. Mark a criterion " <>
        "status='not_applicable' (score=1.0) only when the diff genuinely does not " <>
        "touch the mechanism the criterion governs. Respond with JSON ONLY matching " <>
        "the requested schema."

    rubric_payload = %{
      "matched_rubrics" => merged.matched_rubrics,
      "criteria" =>
        Enum.map(merged.criteria, fn c ->
          %{
            "id" => c["id"],
            "rubric" => c["rubric"],
            "weight" => c["normalized_weight"],
            "inspect" => Map.get(c, "inspect", ["diff"]),
            "check" => c["check"]
          }
        end),
      "penalties" =>
        Enum.map(merged.penalties, fn p ->
          %{
            "id" => p["id"],
            "rubric" => p["rubric"],
            "penalty" => p["penalty"],
            "check" => p["check"]
          }
        end)
    }

    sections =
      [
        "## Active Rubric\n```json\n#{Jason.encode!(rubric_payload, pretty: true)}\n```",
        "## Changed Files\n" <> Enum.map_join(changed_files, "\n", &"- `#{&1}`"),
        "## Diff Stat\n```\n#{diff_stat}\n```",
        "## Unified Diff\n```diff\n#{diff_body}\n```"
      ]
      |> maybe_append_logs(raw_logs)
      |> Kernel.++([response_schema_instructions()])

    [
      %{"role" => "system", "content" => system_prompt},
      %{"role" => "user", "content" => Enum.join(sections, "\n\n")}
    ]
  end

  @doc "Deterministically scores a critic JSON response against the active rubric."
  @spec score_critic_response(map(), map()) :: map()
  def score_critic_response(merged, raw_response) when is_map(raw_response) do
    returned_scores =
      raw_response
      |> Map.get("scores", [])
      |> Enum.filter(&is_map/1)
      |> Map.new(&{&1["id"], &1})

    {evaluated_rev, weight_sum, weighted_score} =
      Enum.reduce(merged.criteria, {[], 0.0, 0.0}, fn crit, acc ->
        score_single_criterion(crit, Map.get(returned_scores, crit["id"]), acc)
      end)

    base_score = if weight_sum > 0, do: weighted_score / weight_sum, else: 1.0
    {triggered, penalty_total} = score_penalties(merged.penalties, raw_response)
    final_score = clamp(Float.round(base_score + penalty_total, 4), 0.0, 1.0)

    %{
      matched_rubrics: merged.matched_rubrics,
      summary: raw_response |> Map.get("summary", "") |> to_string() |> String.trim(),
      base_score: Float.round(base_score, 4),
      penalty_total: Float.round(penalty_total, 4),
      final_score: final_score,
      scores: Enum.reverse(evaluated_rev),
      penalties_triggered: triggered
    }
  end

  @doc "Renders a scored result into a sticky GitHub PR comment in Markdown."
  @spec render_markdown(map(), String.t()) :: String.t()
  def render_markdown(result, model) when is_map(result) and is_binary(model) do
    pct = round(result.final_score * 100)
    rubrics_label = Enum.map_join(result.matched_rubrics, ", ", &"`#{&1}`")

    header =
      [
        @comment_marker,
        "### Rubric Review — **#{pct}/100** (`#{model}`)",
        "",
        "**Active rubrics:** #{rubrics_label}"
      ] ++ if(result.summary != "", do: ["", result.summary], else: [])

    table_header = [
      "",
      "| Rubric | Criterion | Status | Score | Evidence |",
      "|---|---|---|---:|---|"
    ]

    table_rows = Enum.map(result.scores, &format_score_row/1)
    penalty_lines = format_penalty_section(result.penalties_triggered)

    footer = [
      "",
      "_Base score: #{format_two(result.base_score)} · " <>
        "Penalties: #{format_signed_two(result.penalty_total)} · " <>
        "Final: #{format_two(result.final_score)} (advisory check)_"
    ]

    Enum.join(header ++ table_header ++ table_rows ++ penalty_lines ++ footer, "\n") <> "\n"
  end

  @doc """
  Calls an OpenAI-compatible `/chat/completions` endpoint over `Req` and parses
  the critic's JSON response.
  """
  @spec call_critic(keyword(), [map()]) :: {:ok, map()} | {:error, term()}
  def call_critic(opts, messages) when is_list(opts) and is_list(messages) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)
    req_options = Keyword.get(opts, :req_options, [])

    payload = %{
      "model" => model,
      "temperature" => 0.0,
      "response_format" => %{"type" => "json_object"},
      "messages" => messages
    }

    req_opts =
      Keyword.merge(
        [
          url: "#{base_url}/chat/completions",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"user-agent", "zaimu-tomo-rubric-review/1.0"}
          ],
          json: payload,
          receive_timeout: 300_000
        ],
        req_options
      )

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_critic_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, inspect(body) |> String.slice(0, 400)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc "Validates all `.rubrics/*.yaml` files in `rubrics_dir`."
  @spec validate_dir(Path.t(), Path.t()) :: {:ok, non_neg_integer()} | {:error, [String.t()]}
  def validate_dir(rubrics_dir, repo_root \\ ".") do
    case load_dir(rubrics_dir) do
      [] ->
        {:error, ["no *.yaml rubrics found in #{rubrics_dir}"]}

      rubrics ->
        errors =
          Enum.flat_map(rubrics, fn {path, data} ->
            validate(data, Path.relative_to(path, repo_root))
          end)

        if errors == [], do: {:ok, length(rubrics)}, else: {:error, errors}
    end
  end

  @doc """
  End-to-end runner used by `mix zaimu_tomo.rubric_review`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    repo_root = opts |> Keyword.get(:repo_root, ".") |> Path.expand()
    rubrics_dir = resolve_path(Keyword.get(opts, :rubrics_dir, ".rubrics"), repo_root)

    with {:ok, repo_rubrics} <- load_and_validate_repo(rubrics_dir, repo_root),
         {:ok, task_rubric} <- load_and_validate_task(opts) do
      if Keyword.get(opts, :validate_only, false) do
        {:ok, %{mode: :validate_only, count: length(repo_rubrics)}}
      else
        run_review(repo_rubrics, task_rubric, repo_root, opts)
      end
    end
  end

  # -- Run orchestration --

  defp load_and_validate_repo(rubrics_dir, repo_root) do
    case load_dir(rubrics_dir) do
      [] ->
        {:error, {:validation_failed, ["no *.yaml rubrics found in #{rubrics_dir}"]}}

      rubrics ->
        errors =
          Enum.flat_map(rubrics, fn {path, data} ->
            validate(data, Path.relative_to(path, repo_root))
          end)

        if errors == [], do: {:ok, rubrics}, else: {:error, {:validation_failed, errors}}
    end
  end

  defp load_and_validate_task(opts) do
    cond do
      is_binary(opts[:task_rubric]) and opts[:task_rubric] != "" ->
        parsed = opts[:task_rubric] |> File.read!() |> Yaml.parse()
        validate_optional_task(parsed, opts[:task_rubric])

      is_binary(opts[:pr_body_file]) and File.exists?(opts[:pr_body_file]) ->
        parsed = opts[:pr_body_file] |> File.read!() |> extract_from_pr_body()
        validate_optional_task(parsed, "pr_body:rubric")

      true ->
        {:ok, nil}
    end
  end

  defp validate_optional_task(nil, _source), do: {:ok, nil}

  defp validate_optional_task(parsed, source) do
    case validate(parsed, source) do
      [] -> {:ok, parsed}
      errors -> {:error, {:validation_failed, errors}}
    end
  end

  defp run_review(repo_rubrics, task_rubric, repo_root, opts) do
    base = Keyword.get(opts, :base, "origin/main")
    head = Keyword.get(opts, :head, "HEAD")
    max_chars = Keyword.get(opts, :max_diff_chars, @default_max_diff_chars)

    with {:ok, git_ctx} <- collect_git_context(repo_root, base, head, max_chars) do
      merged = select_and_merge(repo_rubrics, git_ctx.changed_files, task_rubric)

      cond do
        git_ctx.changed_files == [] ->
          {:ok, %{mode: :skipped, reason: :no_changed_files}}

        merged.criteria == [] ->
          {:ok, %{mode: :skipped, reason: :no_matching_rubrics}}

        true ->
          execute_or_dry_run(merged, git_ctx, opts)
      end
    end
  end

  defp execute_or_dry_run(merged, git_ctx, opts) do
    raw_logs = read_optional_file(opts[:logs_file])

    messages =
      build_critic_messages(
        merged,
        git_ctx.changed_files,
        git_ctx.diff_stat,
        git_ctx.diff_body,
        raw_logs
      )

    maybe_write_prompt(opts[:render_prompt], messages)

    if Keyword.get(opts, :dry_run, false) do
      {:ok,
       %{
         mode: :dry_run,
         changed_files: length(git_ctx.changed_files),
         matched_rubrics: merged.matched_rubrics,
         active_criteria: Enum.map(merged.criteria, & &1["id"]),
         active_penalties: Enum.map(merged.penalties, & &1["id"]),
         diff_chars: String.length(git_ctx.diff_body)
       }}
    else
      execute_live_critic(merged, messages, opts)
    end
  end

  defp execute_live_critic(merged, messages, opts) do
    api_key = opts[:api_key] || System.get_env("RUBRIC_LLM_API_KEY", "") |> String.trim()
    base_url = opts[:base_url] || System.get_env("RUBRIC_LLM_BASE_URL", @default_base_url)
    model = opts[:model] || System.get_env("RUBRIC_LLM_MODEL", @default_model)

    if api_key == "" do
      {:ok, %{mode: :skipped, reason: :missing_api_key}}
    else
      critic_opts = [
        api_key: api_key,
        base_url: base_url,
        model: model,
        req_options: Keyword.get(opts, :req_options, [])
      ]

      with {:ok, raw_response} <- call_critic(critic_opts, messages) do
        result = score_critic_response(merged, raw_response)
        markdown = render_markdown(result, model)
        maybe_write_file(opts[:output_json], Jason.encode!(result, pretty: true) <> "\n")
        maybe_write_file(opts[:output_md], markdown)

        {:ok, %{mode: :live, result: result, markdown: markdown}}
      end
    end
  end

  # -- Validation helpers --

  defp check_name(errors, rubric, source) do
    case rubric["name"] do
      name when is_binary(name) and byte_size(name) > 0 ->
        if String.trim(name) == "",
          do: ["#{source}: missing non-empty string 'name'" | errors],
          else: errors

      _ ->
        ["#{source}: missing non-empty string 'name'" | errors]
    end
  end

  defp check_paths(errors, rubric, source) do
    case rubric["paths"] do
      nil ->
        errors

      paths when is_list(paths) ->
        if Enum.all?(paths, &(is_binary(&1) and String.trim(&1) != "")) do
          errors
        else
          ["#{source}: 'paths' must be a list of non-empty globs" | errors]
        end

      _ ->
        ["#{source}: 'paths' must be a list of non-empty globs" | errors]
    end
  end

  defp check_criteria(errors, rubric, source) do
    case rubric["criteria"] do
      criteria when is_list(criteria) and criteria != [] ->
        {errs, _seen} =
          criteria
          |> Enum.with_index()
          |> Enum.reduce({errors, MapSet.new()}, fn {crit, idx}, acc ->
            validate_criterion(crit, "#{source}: criteria[#{idx}]", acc)
          end)

        errs

      _ ->
        ["#{source}: must define a non-empty 'criteria' list" | errors]
    end
  end

  defp validate_criterion(crit, prefix, {errors, seen}) when is_map(crit) do
    {errors, seen} = check_snake_id(crit["id"], prefix, errors, seen)
    errors = check_weight(crit["weight"], "#{prefix} (#{crit["id"]})", errors)
    errors = check_non_empty_check(crit["check"], "#{prefix} (#{crit["id"]})", errors)
    {errors, seen}
  end

  defp validate_criterion(_other, prefix, {errors, seen}),
    do: {["#{prefix} must be a mapping" | errors], seen}

  defp check_penalties(errors, rubric, source) do
    case rubric["penalties"] do
      nil ->
        errors

      penalties when is_list(penalties) ->
        {errs, _seen} =
          penalties
          |> Enum.with_index()
          |> Enum.reduce({errors, MapSet.new()}, fn {pen, idx}, acc ->
            validate_penalty(pen, "#{source}: penalties[#{idx}]", acc)
          end)

        errs

      _ ->
        ["#{source}: 'penalties' must be a list" | errors]
    end
  end

  defp validate_penalty(pen, prefix, {errors, seen}) when is_map(pen) do
    {errors, seen} = check_snake_id(pen["id"], prefix, errors, seen)
    errors = check_penalty_value(pen["penalty"], "#{prefix} (#{pen["id"]})", errors)
    errors = check_non_empty_check(pen["check"], "#{prefix} (#{pen["id"]})", errors)
    {errors, seen}
  end

  defp validate_penalty(_other, prefix, {errors, seen}),
    do: {["#{prefix} must be a mapping" | errors], seen}

  defp check_snake_id(id, prefix, errors, seen) when is_binary(id) do
    cond do
      not Regex.match?(~r/\A[a-z0-9_]+\z/, id) ->
        {["#{prefix}: invalid id #{inspect(id)} (use snake_case)" | errors], seen}

      MapSet.member?(seen, id) ->
        {["#{prefix}: duplicate id #{inspect(id)}" | errors], seen}

      true ->
        {errors, MapSet.put(seen, id)}
    end
  end

  defp check_snake_id(id, prefix, errors, seen),
    do: {["#{prefix}: invalid id #{inspect(id)} (use snake_case)" | errors], seen}

  defp check_weight(w, _prefix, errors) when is_number(w) and w > 0 and w <= 1.0, do: errors
  defp check_weight(_w, prefix, errors), do: ["#{prefix}: weight must be in (0, 1]" | errors]

  defp check_penalty_value(p, _prefix, errors) when is_number(p) and p < 0 and p >= -1.0,
    do: errors

  defp check_penalty_value(_p, prefix, errors),
    do: ["#{prefix}: penalty must be in [-1, 0)" | errors]

  defp check_non_empty_check(check, prefix, errors) when is_binary(check) do
    if String.trim(check) == "",
      do: ["#{prefix}: missing non-empty 'check'" | errors],
      else: errors
  end

  defp check_non_empty_check(_other, prefix, errors),
    do: ["#{prefix}: missing non-empty 'check'" | errors]

  # -- Glob & merge helpers --

  defp translate_glob("", acc), do: acc
  defp translate_glob("**/" <> rest, acc), do: translate_glob(rest, acc <> "(?:.*/)?")
  defp translate_glob("**" <> rest, acc), do: translate_glob(rest, acc <> ".*")
  defp translate_glob("*" <> rest, acc), do: translate_glob(rest, acc <> "[^/]*")
  defp translate_glob("?" <> rest, acc), do: translate_glob(rest, acc <> "[^/]")

  defp translate_glob(<<ch::utf8, rest::binary>>, acc),
    do: translate_glob(rest, acc <> Regex.escape(<<ch::utf8>>))

  defp rubric_matches?(rubric, changed_files) do
    case rubric["paths"] do
      nil -> true
      [] -> true
      patterns -> Enum.any?(changed_files, &path_matches_any?(&1, patterns))
    end
  end

  defp merge_rubric(rubric, {names, c_order, c_map, p_order, p_map}) do
    name = rubric["name"]

    {c_order, c_map} =
      Enum.reduce(rubric["criteria"] || [], {c_order, c_map}, &put_ordered(&1, name, &2))

    {p_order, p_map} =
      Enum.reduce(rubric["penalties"] || [], {p_order, p_map}, &put_ordered(&1, name, &2))

    {[name | names], c_order, c_map, p_order, p_map}
  end

  defp put_ordered(item, rubric_name, {order, map}) do
    id = item["id"]
    entry = Map.put(item, "rubric", rubric_name)
    next_order = if Map.has_key?(map, id), do: order, else: [id | order]
    {next_order, Map.put(map, id, entry)}
  end

  defp normalize_weights(criteria) do
    total = Enum.reduce(criteria, 0.0, fn c, acc -> acc + c["weight"] * 1.0 end)

    if total > 0 do
      Enum.map(criteria, &Map.put(&1, "normalized_weight", Float.round(&1["weight"] / total, 6)))
    else
      criteria
    end
  end

  # -- Scoring & formatting helpers --

  defp score_single_criterion(crit, nil, {acc, w_sum, w_score}) do
    weight = crit["weight"] * 1.0

    row = %{
      id: crit["id"],
      rubric: crit["rubric"],
      weight: weight,
      score: 0.0,
      status: "fail",
      evidence: "Missing from critic output."
    }

    {[row | acc], w_sum + weight, w_score}
  end

  defp score_single_criterion(crit, item, {acc, w_sum, w_score}) do
    weight = crit["weight"] * 1.0
    status = normalize_status(item["status"])
    score = if status == "not_applicable", do: 1.0, else: snap_score(item["score"])
    evidence = normalize_evidence(item["evidence"])

    row = %{
      id: crit["id"],
      rubric: crit["rubric"],
      weight: weight,
      score: score,
      status: status,
      evidence: evidence
    }

    if status == "not_applicable" do
      {[row | acc], w_sum, w_score}
    else
      {[row | acc], w_sum + weight, w_score + weight * score}
    end
  end

  defp score_penalties(penalties, raw_response) do
    penalties_map = Map.new(penalties, &{&1["id"], &1})

    {triggered_rev, _seen, total} =
      raw_response
      |> Map.get("penalties_triggered", [])
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({[], MapSet.new(), 0.0}, fn item, {acc, seen, sum} ->
        pid = item["id"]
        evidence = item |> Map.get("evidence", "") |> to_string() |> String.trim()

        if Map.has_key?(penalties_map, pid) and not MapSet.member?(seen, pid) and evidence != "" do
          pen = penalties_map[pid]
          pval = pen["penalty"] * 1.0
          entry = %{id: pid, rubric: pen["rubric"], penalty: pval, evidence: evidence}
          {[entry | acc], MapSet.put(seen, pid), sum + pval}
        else
          {acc, seen, sum}
        end
      end)

    {Enum.reverse(triggered_rev), total}
  end

  defp normalize_status(status) do
    down = status |> to_string() |> String.downcase()
    if down in @valid_statuses, do: down, else: "fail"
  end

  defp snap_score(val) when is_number(val) do
    Enum.min_by(@valid_scores, &abs(&1 - val))
  end

  defp snap_score(_other), do: 0.0

  defp normalize_evidence(ev) do
    case ev |> to_string() |> String.trim() do
      "" -> "No evidence cited."
      text -> text
    end
  end

  defp decode_critic_body(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/s, "")
      |> String.replace(~r/\s*```\z/s, "")

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_critic_json, other}}
      {:error, reason} -> {:error, {:invalid_critic_json, reason}}
    end
  end

  defp decode_critic_body(other), do: {:error, {:unexpected_llm_response, other}}

  defp format_score_row(row) do
    status_label = if row.status == "fail", do: "FAIL", else: status_short(row.status)

    score_str =
      if row.status == "not_applicable",
        do: "—",
        else: :erlang.float_to_binary(row.score, decimals: 1)

    evidence =
      row.evidence
      |> String.replace("\n", " ")
      |> String.replace("|", "\\|")

    "| `#{row.rubric}` | `#{row.id}` | #{status_label} | #{score_str} | #{evidence} |"
  end

  defp status_short("not_applicable"), do: "n/a"
  defp status_short(other), do: other

  defp format_penalty_section([]), do: []

  defp format_penalty_section(penalties) do
    items =
      Enum.map(penalties, fn pen ->
        ev = String.replace(pen.evidence, "\n", " ")
        "- **`#{pen.id}` (#{format_signed_two(pen.penalty)})** (`#{pen.rubric}`): #{ev}"
      end)

    ["", "#### Penalties Triggered", ""] ++ items
  end

  defp format_two(num), do: :erlang.float_to_binary(num * 1.0, decimals: 2)

  defp format_signed_two(num) do
    prefix = if num >= 0, do: "+", else: ""
    prefix <> format_two(num)
  end

  defp clamp(val, lo, hi), do: val |> max(lo) |> min(hi)

  # -- Git & IO helpers --

  defp git_cmd(args, repo_root) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:git_failed, code, String.trim(output)}}
    end
  end

  defp truncate_diff(diff, max_chars) do
    if String.length(diff) > max_chars do
      String.slice(diff, 0, max_chars) <>
        "\n\n... [diff truncated at #{max_chars} chars; see diff --stat above] ...\n"
    else
      diff
    end
  end

  defp maybe_append_logs(sections, ""), do: sections

  defp maybe_append_logs(sections, raw_logs) do
    trimmed = String.trim(raw_logs)

    if trimmed == "" do
      sections
    else
      tail = String.slice(trimmed, -12_000, 12_000)
      sections ++ ["## Raw Verification Logs\n```\n#{tail}\n```"]
    end
  end

  defp response_schema_instructions do
    """
    ## Required JSON Response Schema
    Return a single valid JSON object (no markdown fences) with:
    {
      "summary": "1-3 sentence overall review verdict",
      "scores": [
        {
          "id": "<criterion_id>",
          "score": 1.0 | 0.5 | 0.0,
          "status": "pass" | "partial" | "fail" | "not_applicable",
          "evidence": "<exact file:line or concise grounding>"
        }
      ],
      "penalties_triggered": [
        {
          "id": "<penalty_id>",
          "evidence": "<exact file:line and concrete violation>"
        }
      ]
    }
    """
    |> String.trim()
  end

  defp resolve_path(path, repo_root) do
    if Path.type(path) == :absolute, do: path, else: Path.join(repo_root, path)
  end

  defp read_optional_file(path) when is_binary(path) and path != "" do
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp read_optional_file(_), do: ""

  defp maybe_write_prompt(path, [system_msg, user_msg]) when is_binary(path) and path != "" do
    content = "# System\n\n#{system_msg["content"]}\n\n# User\n\n#{user_msg["content"]}\n"
    File.write!(path, content)
  end

  defp maybe_write_prompt(_, _), do: :ok

  defp maybe_write_file(path, content) when is_binary(path) and path != "" do
    File.write!(path, content)
  end

  defp maybe_write_file(_, _), do: :ok
end
