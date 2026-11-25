defmodule ZaimuTomo.Statements.InvariantsTest do
  use ExUnit.Case, async: true

  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.LLMClient
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.ParsedStatement

  @statement_mod [:ZaimuTomo, :Statements, :Statement]
  @statement_line_mod [:ZaimuTomo, :Statements, :StatementLine]
  @extract_job_mod [:ZaimuTomo, :Statements, :ExtractJob]
  @repo_mod [:ZaimuTomo, :Repo]
  @multi_mod [:Ecto, :Multi]
  @changeset_mod [:Ecto, :Changeset]

  @repo_writes [
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_or_update,
    :insert_or_update!,
    :insert_all,
    :update_all,
    :delete_all
  ]

  @multi_writes [
    :insert,
    :update,
    :delete,
    :insert_or_update,
    :insert_all,
    :update_all,
    :delete_all
  ]

  @extraction_fact_fields MapSet.new([
                            :extracted_at,
                            :failure_code,
                            :account_ref,
                            :period_start,
                            :period_end,
                            :opening_balance_cents,
                            :closing_balance_cents
                          ])

  @extraction_fact_field_strings MapSet.new(@extraction_fact_fields, &Atom.to_string/1)

  describe "lib/ statement architecture invariants" do
    test "every .ex file under lib/ obeys context-boundary and single-writer rules" do
      files =
        "../../../lib/**/*.ex"
        |> Path.expand(__DIR__)
        |> Path.wildcard()
        |> Enum.sort()

      assert files != []

      violations = Enum.flat_map(files, &check_file/1)
      message = "Statement invariant violations found:\n#{format_violations(violations)}"

      assert violations == [], message
    end
  end

  describe "AST invariant checker self-tests" do
    test "flags aliased Repo.insert(%Statement{}) outside ZaimuTomo.Statements" do
      source = """
      defmodule ZaimuTomoWeb.RogueLive do
        alias ZaimuTomo.Repo, as: DB
        alias ZaimuTomo.Statements.Statement, as: Stmt

        def insert_directly do
          DB.insert(%Stmt{})
        end
      end
      """

      violations = check_source(source)

      assert Enum.any?(violations, &(&1.rule == :write_outside_context))
    end

    test "flags piped Repo.update on a Statement outside ZaimuTomo.Statements" do
      source = """
      defmodule ZaimuTomoWeb.RogueLive do
        alias ZaimuTomo.Repo
        alias ZaimuTomo.Statements.Statement

        def rename(%Statement{} = statement) do
          statement
          |> Ecto.Changeset.change(filename: "renamed.pdf")
          |> Repo.update()
        end
      end
      """

      violations = check_source(source)

      assert Enum.any?(violations, &(&1.rule == :write_outside_context))
    end

    test "flags Multi.insert with Statement.upload_changeset outside ZaimuTomo.Statements" do
      source = """
      defmodule ZaimuTomoWeb.RogueController do
        alias Ecto.Multi
        alias ZaimuTomo.Statements.Statement

        def create(attrs) do
          Multi.new()
          |> Multi.insert(:s, Statement.upload_changeset(%Statement{}, attrs))
        end
      end
      """

      violations = check_source(source)

      assert Enum.any?(violations, &(&1.rule == :upload_changeset_outside_context))
      assert Enum.any?(violations, &(&1.rule == :write_outside_context))
    end

    test "flags StatementLine writes inside ZaimuTomo.Statements outside ExtractJob" do
      source = """
      defmodule ZaimuTomo.Statements.RogueBackfill do
        alias ZaimuTomo.Repo
        alias ZaimuTomo.Statements.{Statement, StatementLine}

        def insert_lines(rows) do
          Repo.insert_all(StatementLine, rows)
        end

        def clear_lines(statement_id) do
          from(l in StatementLine, where: l.statement_id == ^statement_id)
          |> Repo.delete_all()
        end
      end
      """

      violations = check_source(source)

      assert length(violations) == 2
      assert Enum.all?(violations, &(&1.rule == :statement_line_write_outside_extract_job))
    end

    test "flags writing extraction-fact fields on Statement outside ExtractJob" do
      source = """
      defmodule ZaimuTomo.Statements.RogueUpdater do
        import Ecto.Changeset

        alias ZaimuTomo.Repo
        alias ZaimuTomo.Statements.Statement

        def mark_failed(%Statement{} = statement) do
          statement
          |> Ecto.Changeset.change(failure_code: "oops")
          |> Repo.update()
        end

        def mark_extracted(%Statement{} = statement) do
          statement
          |> change(%{extracted_at: DateTime.utc_now()})
          |> Repo.update()
        end

        def cast_period(statement, attrs) do
          cast(statement, attrs, [:period_start, :period_end])
        end

        def force_opening(changeset) do
          put_change(changeset, :opening_balance_cents, 0)
        end

        def bulk_clear(id) do
          Repo.update_all(Statement, set: [closing_balance_cents: 0, account_ref: "CH93"])
        end
      end
      """

      violations = check_source(source)
      rules = Enum.map(violations, & &1.rule)
      details = Enum.map(violations, & &1.detail)

      assert Enum.all?(rules, &(&1 == :extraction_fact_write_outside_extract_job))
      assert Enum.any?(details, &String.contains?(&1, ":failure_code"))
      assert Enum.any?(details, &String.contains?(&1, ":extracted_at"))
      assert Enum.any?(details, &String.contains?(&1, ":period_start"))
      assert Enum.any?(details, &String.contains?(&1, ":period_end"))
      assert Enum.any?(details, &String.contains?(&1, ":opening_balance_cents"))
      assert Enum.any?(details, &String.contains?(&1, ":closing_balance_cents"))
      assert Enum.any?(details, &String.contains?(&1, ":account_ref"))
    end

    test "allows read-only Statement and StatementLine references outside ZaimuTomo.Statements" do
      source = """
      defmodule ZaimuTomoWeb.StatementLive.Show do
        alias ZaimuTomo.Statements
        alias ZaimuTomo.Statements.{Statement, StatementLine}

        def render_status(%Statement{lines: [%StatementLine{} | _]} = statement) do
          Statements.status(statement, false)
        end
      end
      """

      assert check_source(source) == []
    end

    test "allows ExtractJob to write extraction facts and StatementLine rows" do
      source = """
      defmodule ZaimuTomo.Statements.ExtractJob do
        alias ZaimuTomo.Repo
        alias ZaimuTomo.Statements.{Statement, StatementLine}

        def persist(%Statement{} = statement, rows) do
          Repo.delete_all(StatementLine)
          statement |> Ecto.Changeset.change(extracted_at: DateTime.utc_now()) |> Repo.update()
          Repo.insert_all(StatementLine, rows)
        end
      end
      """

      assert check_source(source) == []
    end
  end

  describe "Langfuse extract-statement-page prompt variable contract" do
    test "LLMClient.statement_page_prompt_variables/2 matches the local prompt placeholders" do
      assert {:ok, template_vars} = Langfuse.local_prompt_variables("extract-statement-page")

      vars =
        LLMClient.statement_page_prompt_variables("ocr text", %{
          page: 1,
          pages: 2,
          account_type: :credit_card,
          currency: "CHF",
          period: nil
        })

      assert MapSet.new(template_vars) == MapSet.new(Map.keys(vars), &Atom.to_string/1)
    end

    test "local_prompt_variables/1 returns an error for unknown prompts" do
      assert {:error, {:local_prompt_not_found, "does-not-exist"}} =
               Langfuse.local_prompt_variables("does-not-exist")
    end
  end

  describe "failure descriptions" do
    test "every ParsedStatement refusal and duplicate_period has a dedicated description" do
      failures = ParsedStatement.failures()
      assert Enum.any?(failures)

      codes = Enum.map(failures, &Atom.to_string/1) ++ ["duplicate_period"]

      for code <- codes do
        description = Statements.describe_failure(code)

        assert description != "",
               "expected a non-empty description for #{inspect(code)}"

        assert description != "an unexpected error",
               "expected a dedicated description for #{inspect(code)}"
      end
    end

    test "every non-service summary code has a dedicated description" do
      codes = [
        "validation_failed",
        "missing_structured_output",
        "missing_prompt_variables",
        "local_prompt_not_found",
        "langfuse_prompt_api_not_configured",
        "invalid_langfuse_prompt_response",
        "prompt_fetcher_failed",
        "unexpected_api_structure",
        "persistence_failed",
        "job_timeout",
        "job_interrupted",
        "invalid_verifier_output",
        "storage:not_found",
        "scratch_unavailable:enospc",
        "ocr_upload_failed:missing_api_key"
      ]

      for code <- codes do
        description = ErrorClassification.describe(code)

        assert description != "",
               "expected a non-empty description for #{inspect(code)}"

        assert description != "an unexpected error",
               "expected a dedicated description for #{inspect(code)}"
      end

      missing_key = ErrorClassification.describe("ocr_upload_failed:missing_api_key")
      refute missing_key =~ "refused the request"
    end
  end

  # -- AST checker implementation --

  defp check_file(path) do
    relative_path = Path.relative_to_cwd(path)

    path
    |> File.read!()
    |> check_source(relative_path)
  end

  defp check_source(source, path \\ "synthetic.ex") do
    source
    |> Code.string_to_quoted!(file: path)
    |> extract_modules([])
    |> Enum.flat_map(&check_module(&1, path))
  end

  defp extract_modules(ast, prefix) do
    {_, modules} = split_nested_modules(ast, prefix)
    Enum.reverse(modules)
  end

  defp split_nested_modules(ast, prefix) do
    Macro.prewalk(ast, [], fn
      {:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, acc ->
        full_name = resolve_defmodule_name(prefix, parts)
        {own_body, nested} = split_nested_modules(body, full_name)
        {nil, [{full_name, own_body} | nested] ++ acc}

      node, acc ->
        {node, acc}
    end)
  end

  defp resolve_defmodule_name(_prefix, [:"Elixir" | rest]), do: rest
  defp resolve_defmodule_name(prefix, parts), do: prefix ++ parts

  defp check_module({module_name, body}, path) do
    ctx = collect_context(module_name, body)

    rule_a_violations(body, ctx, path) ++ rule_b_violations(body, ctx, path)
  end

  defp collect_context(module_name, body) do
    {aliases, imports_changeset?} = collect_directives(body, module_name)
    referenced_mods = collect_referenced_modules(body, aliases, module_name)

    %{
      module_name: module_name,
      aliases: aliases,
      imports_changeset?: imports_changeset?,
      references_statement?:
        module_name == @statement_mod or MapSet.member?(referenced_mods, @statement_mod),
      references_statement_line?:
        module_name == @statement_line_mod or
          MapSet.member?(referenced_mods, @statement_line_mod)
    }
  end

  defp collect_directives(body, module_name) do
    {_, acc} =
      Macro.prewalk(body, {%{}, false}, fn
        {:alias, _meta, [target | rest]}, {aliases, imports_changeset?} ->
          {nil, {put_alias(aliases, target, rest, module_name), imports_changeset?}}

        {:import, _meta, [target | _rest]}, {aliases, imports_changeset?} ->
          imported? = resolve_module(target, aliases, module_name) == @changeset_mod
          {nil, {aliases, imports_changeset? or imported?}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp put_alias(aliases, {{:., _, [prefix_ast, :{}]}, _, items}, _opts, module_name) do
    case resolve_module(prefix_ast, aliases, module_name) do
      [_ | _] = prefix -> put_multi_alias(aliases, prefix, items)
      _ -> aliases
    end
  end

  defp put_alias(aliases, target_ast, opts_list, module_name) do
    case resolve_module(target_ast, aliases, module_name) do
      [_ | _] = resolved ->
        key = alias_as_name(opts_list) || List.last(resolved)
        Map.put(aliases, key, resolved)

      _ ->
        aliases
    end
  end

  defp put_multi_alias(aliases, prefix, items) do
    Enum.reduce(items, aliases, fn
      {:__aliases__, _, [_ | _] = sub_parts}, acc ->
        Map.put(acc, List.last(sub_parts), prefix ++ sub_parts)

      _other, acc ->
        acc
    end)
  end

  defp alias_as_name([opts]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as_name]} -> as_name
      _ -> nil
    end
  end

  defp alias_as_name(_opts_list), do: nil

  defp collect_referenced_modules(body, aliases, module_name) do
    initial = MapSet.new(Map.values(aliases))

    {_, mods} =
      Macro.prewalk(body, initial, fn
        {:alias, _, _}, acc -> {nil, acc}
        {:import, _, _}, acc -> {nil, acc}
        node, acc -> maybe_put_resolved(node, acc, aliases, module_name)
      end)

    mods
  end

  defp maybe_put_resolved(node, acc, aliases, module_name) do
    case resolve_module(node, aliases, module_name) do
      nil -> {node, acc}
      resolved -> {nil, MapSet.put(acc, resolved)}
    end
  end

  defp resolve_module({:__MODULE__, _, context}, _aliases, module_name) when is_atom(context),
    do: module_name

  defp resolve_module({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, _aliases, module_name),
    do: module_name ++ rest

  defp resolve_module({:__aliases__, _, [:"Elixir" | rest]}, _aliases, _module_name), do: rest

  defp resolve_module({:__aliases__, _, [first | rest]}, aliases, _module_name)
       when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, target} -> target ++ rest
      :error -> [first | rest]
    end
  end

  defp resolve_module(_node, _aliases, _module_name), do: nil

  defp in_statements_context?([:ZaimuTomo, :Statements | _]), do: true
  defp in_statements_context?(_module_name), do: false

  defp write_call?(@repo_mod, fun) when fun in @repo_writes, do: true
  defp write_call?(@multi_mod, fun) when fun in @multi_writes, do: true
  defp write_call?(_mod, _fun), do: false

  # -- Rule A: context boundary --

  defp rule_a_violations(body, ctx, path) do
    if in_statements_context?(ctx.module_name) do
      []
    else
      collect_rule_a(body, ctx, path)
    end
  end

  defp collect_rule_a(body, ctx, path) do
    references_schema? = ctx.references_statement? or ctx.references_statement_line?

    {_, violations} =
      Macro.prewalk(body, [], fn
        {:alias, _, _}, acc ->
          {nil, acc}

        {:import, _, _}, acc ->
          {nil, acc}

        {{:., _, [mod_ast, fun]}, meta, _args} = node, acc ->
          new = rule_a_call_violations(mod_ast, fun, meta, ctx, references_schema?, path)
          {node, new ++ acc}

        node, acc ->
          {node, acc}
      end)

    violations |> Enum.reverse() |> Enum.uniq()
  end

  defp rule_a_call_violations(mod_ast, fun, meta, ctx, references_schema?, path) do
    mod = resolve_module(mod_ast, ctx.aliases, ctx.module_name)

    upload_violation =
      if mod == @statement_mod and fun == :upload_changeset do
        [
          violation(
            path,
            meta,
            ctx.module_name,
            :upload_changeset_outside_context,
            "Statement.upload_changeset"
          )
        ]
      else
        []
      end

    write_violation =
      if references_schema? and write_call?(mod, fun) do
        [
          violation(
            path,
            meta,
            ctx.module_name,
            :write_outside_context,
            "#{format_mod(mod)}.#{fun}"
          )
        ]
      else
        []
      end

    upload_violation ++ write_violation
  end

  # -- Rule B: single writer of extraction facts & lines --

  defp rule_b_violations(body, ctx, path) do
    if ctx.module_name == @extract_job_mod do
      []
    else
      collect_rule_b(body, ctx, path)
    end
  end

  defp collect_rule_b(body, ctx, path) do
    {_, violations} =
      Macro.prewalk(body, [], fn
        {:alias, _, _}, acc -> {nil, acc}
        {:import, _, _}, acc -> {nil, acc}
        node, acc -> {node, rule_b_node_violations(node, ctx, path) ++ acc}
      end)

    violations |> Enum.reverse() |> Enum.uniq()
  end

  defp rule_b_node_violations(
         {:|>, _pipe_meta, [lhs, {{:., _, [mod_ast, fun]}, meta, args}]},
         ctx,
         path
       ) do
    piped_line_write_violation(lhs, mod_ast, fun, args, meta, ctx, path)
  end

  defp rule_b_node_violations({{:., _, [mod_ast, fun]}, meta, args}, ctx, path)
       when is_list(args) do
    remote_rule_b_violations(mod_ast, fun, args, meta, ctx, path)
  end

  defp rule_b_node_violations({fun, meta, args}, ctx, path)
       when is_atom(fun) and is_list(args) do
    local_extraction_fact_violations(fun, args, meta, ctx, path)
  end

  defp rule_b_node_violations(_node, _ctx, _path), do: []

  defp piped_line_write_violation(lhs, mod_ast, fun, args, meta, ctx, path) do
    mod = resolve_module(mod_ast, ctx.aliases, ctx.module_name)

    if write_call?(mod, fun) and
         ast_references_module?([lhs, args], ctx.aliases, ctx.module_name, @statement_line_mod) do
      [line_write_violation(path, meta, ctx.module_name, mod, fun)]
    else
      []
    end
  end

  defp remote_rule_b_violations(mod_ast, fun, args, meta, ctx, path) do
    mod = resolve_module(mod_ast, ctx.aliases, ctx.module_name)

    direct_line_write_violation(mod, fun, args, meta, ctx, path) ++
      remote_extraction_fact_violations(mod, fun, args, meta, ctx, path)
  end

  defp direct_line_write_violation(mod, fun, args, meta, ctx, path) do
    if write_call?(mod, fun) and
         ast_references_module?(args, ctx.aliases, ctx.module_name, @statement_line_mod) do
      [line_write_violation(path, meta, ctx.module_name, mod, fun)]
    else
      []
    end
  end

  defp remote_extraction_fact_violations(mod, fun, args, meta, ctx, path) do
    if ctx.references_statement? do
      call = "#{format_mod(mod)}.#{fun}"

      mod
      |> remote_written_fields(fun, args)
      |> Enum.map(&extraction_fact_violation(path, meta, ctx.module_name, call, &1))
    else
      []
    end
  end

  defp local_extraction_fact_violations(fun, args, meta, ctx, path) do
    if ctx.references_statement? and ctx.imports_changeset? do
      call = Atom.to_string(fun)

      fun
      |> changeset_written_fields(args)
      |> Enum.map(&extraction_fact_violation(path, meta, ctx.module_name, call, &1))
    else
      []
    end
  end

  defp remote_written_fields(@changeset_mod, fun, args), do: changeset_written_fields(fun, args)

  defp remote_written_fields(mod, :update_all, args) when mod in [@repo_mod, @multi_mod],
    do: update_all_set_fields(args)

  defp remote_written_fields(_mod, _fun, _args), do: []

  defp changeset_written_fields(:change, args) do
    args
    |> Enum.flat_map(&change_arg_keys/1)
    |> Enum.filter(&extraction_fact_field?/1)
  end

  defp changeset_written_fields(:cast, args) do
    args
    |> Enum.flat_map(&cast_arg_fields/1)
    |> Enum.filter(&extraction_fact_field?/1)
  end

  defp changeset_written_fields(fun, args) when fun in [:put_change, :force_change] do
    args
    |> put_change_field()
    |> List.wrap()
    |> Enum.filter(&extraction_fact_field?/1)
  end

  defp changeset_written_fields(_fun, _args), do: []

  defp change_arg_keys({:%{}, _, pairs}), do: map_pair_keys(pairs)
  defp change_arg_keys(list) when is_list(list), do: keyword_keys(list)
  defp change_arg_keys(_other), do: []

  defp map_pair_keys([{:|, _, [_base, updates]}]), do: keyword_keys(updates)
  defp map_pair_keys(pairs) when is_list(pairs), do: keyword_keys(pairs)
  defp map_pair_keys(_other), do: []

  defp keyword_keys(list) when is_list(list) do
    for {key, _val} <- list, do: key
  end

  defp keyword_keys(_other), do: []

  defp cast_arg_fields(list) when is_list(list) do
    for item <- list, is_atom(item) or is_binary(item), do: item
  end

  defp cast_arg_fields(_other), do: []

  defp put_change_field([field, _value]), do: field
  defp put_change_field([_changeset, field, _value]), do: field
  defp put_change_field(_args), do: nil

  defp update_all_set_fields(args) do
    args
    |> Enum.flat_map(&extract_set_keys/1)
    |> Enum.filter(&extraction_fact_field?/1)
  end

  defp extract_set_keys(arg) when is_list(arg) do
    for {:set, set_list} <- arg, is_list(set_list), key <- keyword_keys(set_list), do: key
  end

  defp extract_set_keys(_arg), do: []

  defp extraction_fact_field?(field) when is_atom(field),
    do: MapSet.member?(@extraction_fact_fields, field)

  defp extraction_fact_field?(field) when is_binary(field),
    do: MapSet.member?(@extraction_fact_field_strings, field)

  defp extraction_fact_field?(_field), do: false

  defp ast_references_module?(ast, aliases, module_name, target_mod) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        _node, true -> {nil, true}
        node, false -> {node, resolve_module(node, aliases, module_name) == target_mod}
      end)

    found?
  end

  defp line_write_violation(path, meta, module_name, mod, fun) do
    violation(
      path,
      meta,
      module_name,
      :statement_line_write_outside_extract_job,
      "#{format_mod(mod)}.#{fun}"
    )
  end

  defp extraction_fact_violation(path, meta, module_name, call, field) do
    violation(
      path,
      meta,
      module_name,
      :extraction_fact_write_outside_extract_job,
      "#{call} writing #{inspect(field)}"
    )
  end

  defp violation(path, meta, module_name, rule, detail) do
    %{
      file: path,
      line: Keyword.get(meta, :line, 0),
      module: format_mod(module_name),
      rule: rule,
      detail: detail
    }
  end

  defp format_mod(parts) when is_list(parts), do: Enum.map_join(parts, ".", &to_string/1)
  defp format_mod(other), do: inspect(other)

  defp format_violations(violations) do
    Enum.map_join(violations, "\n", fn v ->
      "  - #{v.file}:#{v.line} (#{v.module}) [#{v.rule}] #{v.detail}"
    end)
  end
end
