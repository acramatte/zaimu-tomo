defmodule ZaimuTomo.Rubrics.Yaml do
  @moduledoc """
  Minimal pure-Elixir YAML parser for `.rubrics/*.yaml` data files and optional
  PR-body rubric blocks.

  Parses pure data only (string-keyed maps, lists, strings, booleans, numbers)
  without evaluating code or creating dynamic atoms, so it is safe to run on
  untrusted pull request descriptions in CI.
  """

  @doc "Parses a rubric YAML string into a string-keyed map."
  @spec parse(String.t()) :: map()
  def parse(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> parse_root(%{})
  end

  defp parse_root([], acc), do: acc

  defp parse_root([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_root(rest, acc)

      not String.starts_with?(line, " ") and String.contains?(line, ":") ->
        parse_top_entry(line, rest, acc)

      true ->
        parse_root(rest, acc)
    end
  end

  defp parse_top_entry(line, rest, acc) do
    [raw_key, raw_val] = String.split(line, ":", parts: 2)
    key = String.trim(raw_key)
    val = String.trim(raw_val)

    cond do
      val in [">", "|"] ->
        {text, remaining} = collect_block(rest, 2, [])
        parse_root(remaining, Map.put(acc, key, text))

      val != "" ->
        parse_root(rest, Map.put(acc, key, parse_scalar(val)))

      true ->
        {items, remaining} = parse_sequence(rest, [])
        parse_root(remaining, Map.put(acc, key, items))
    end
  end

  defp parse_sequence([], acc), do: {Enum.reverse(acc), []}

  defp parse_sequence([line | rest] = all, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_sequence(rest, acc)

      indent_of(line) == 0 ->
        {Enum.reverse(acc), all}

      String.starts_with?(trimmed, "- ") ->
        parse_sequence_item(
          indent_of(line),
          String.trim(String.slice(trimmed, 2..-1//1)),
          rest,
          acc
        )

      true ->
        parse_sequence(rest, acc)
    end
  end

  defp parse_sequence_item(dash_indent, after_dash, rest, acc) do
    if map_item_start?(after_dash) do
      [k, v] = String.split(after_dash, ":", parts: 2)
      first_map = %{String.trim(k) => parse_scalar(String.trim(v))}
      {item, remaining} = parse_item_fields(rest, dash_indent, first_map)
      parse_sequence(remaining, [item | acc])
    else
      parse_sequence(rest, [parse_scalar(after_dash) | acc])
    end
  end

  defp map_item_start?(str) do
    String.contains?(str, ":") and not String.starts_with?(str, ["\"", "'"])
  end

  defp parse_item_fields([], _dash_indent, item), do: {item, []}

  defp parse_item_fields([line | rest] = all, dash_indent, item) do
    trimmed = String.trim(line)
    indent = indent_of(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_item_fields(rest, dash_indent, item)

      indent < dash_indent + 2 or (indent == dash_indent and String.starts_with?(trimmed, "- ")) ->
        {item, all}

      String.contains?(trimmed, ":") ->
        parse_item_field(trimmed, indent, rest, dash_indent, item)

      true ->
        parse_item_fields(rest, dash_indent, item)
    end
  end

  defp parse_item_field(trimmed, indent, rest, dash_indent, item) do
    [raw_k, raw_v] = String.split(trimmed, ":", parts: 2)
    key = String.trim(raw_k)
    val = String.trim(raw_v)

    if val in [">", "|"] do
      {text, remaining} = collect_block(rest, indent + 2, [])
      parse_item_fields(remaining, dash_indent, Map.put(item, key, text))
    else
      parse_item_fields(rest, dash_indent, Map.put(item, key, parse_scalar(val)))
    end
  end

  defp collect_block([], _min_indent, acc), do: {acc |> Enum.reverse() |> Enum.join(" "), []}

  defp collect_block([line | rest] = all, min_indent, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        collect_block(rest, min_indent, acc)

      indent_of(line) < min_indent ->
        {acc |> Enum.reverse() |> Enum.join(" "), all}

      true ->
        collect_block(rest, min_indent, [trimmed | acc])
    end
  end

  defp parse_scalar(raw) do
    trimmed = String.trim(raw)

    cond do
      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        parse_inline_list(trimmed)

      Regex.match?(~r/\A-?\d+\.\d+\z/, trimmed) ->
        String.to_float(trimmed)

      Regex.match?(~r/\A-?\d+\z/, trimmed) ->
        String.to_integer(trimmed)

      trimmed == "true" ->
        true

      trimmed == "false" ->
        false

      true ->
        strip_quotes(trimmed)
    end
  end

  defp parse_inline_list("[]"), do: []

  defp parse_inline_list(raw) do
    raw
    |> String.slice(1..-2//1)
    |> String.trim()
    |> case do
      "" -> []
      inner -> inner |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> strip_quotes()))
    end
  end

  defp strip_quotes(str) do
    if String.length(str) >= 2 and
         ((String.starts_with?(str, "\"") and String.ends_with?(str, "\"")) or
            (String.starts_with?(str, "'") and String.ends_with?(str, "'"))) do
      String.slice(str, 1..-2//1)
    else
      str
    end
  end

  defp indent_of(line) do
    String.length(line) - String.length(String.trim_leading(line, " "))
  end
end
