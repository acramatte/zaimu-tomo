defmodule ZaimuTomo.Datasets.LangfuseReader do
  @moduledoc """
  Read-only Langfuse Public API client (v3 scores + v2 observations) used to
  optionally enrich canonical dataset builds with historical scores, model
  provenance, token usage, cost, and latency.

  Uses `Req` and the existing `:zaimu_tomo, :langfuse` configuration. Enrichment
  is strictly optional and fail-open per trace so a missing or expired trace
  never blocks building a canonical dataset from PostgreSQL.
  """

  @score_name "user-extraction-thumbs"
  @score_id_prefix "user-extraction-thumbs-"
  @default_from_timestamp "2024-01-01T00:00:00Z"
  @max_pages 100

  @type enrichment :: %{
          configured?: boolean(),
          scores_by_trace: %{String.t() => map()},
          observations_by_trace: %{String.t() => map()},
          warnings: [String.t()]
        }

  @doc """
  Fetches Langfuse scores and per-trace observation summaries for `trace_ids`.

  Returns an unconfigured enrichment map with a warning when Langfuse
  credentials are not configured.
  """
  @spec fetch_enrichment([String.t()], keyword()) :: enrichment()
  def fetch_enrichment(trace_ids, opts \\ []) when is_list(trace_ids) do
    case api_config(opts) do
      {:ok, api} ->
        {scores_by_trace, score_warnings} = fetch_all_scores(api)
        {observations_by_trace, obs_warnings} = fetch_all_observations(trace_ids, api)

        %{
          configured?: true,
          scores_by_trace: scores_by_trace,
          observations_by_trace: observations_by_trace,
          warnings: Enum.reverse(score_warnings ++ obs_warnings)
        }

      {:error, _reason} ->
        %{
          configured?: false,
          scores_by_trace: %{},
          observations_by_trace: %{},
          warnings: ["langfuse enrichment requested but credentials are not configured"]
        }
    end
  end

  defp fetch_all_observations(trace_ids, api) do
    trace_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reduce({%{}, []}, &accumulate_trace_summary(&1, &2, api))
  end

  defp accumulate_trace_summary(trace_id, {acc, warnings}, api) do
    case fetch_trace_summary(trace_id, api) do
      {:ok, summary} -> {Map.put(acc, trace_id, summary), warnings}
      {:error, reason} -> {acc, ["trace #{trace_id}: #{inspect(reason)}" | warnings]}
    end
  end

  @doc "An empty enrichment map used when Langfuse enrichment is disabled."
  @spec empty() :: enrichment()
  def empty do
    %{configured?: false, scores_by_trace: %{}, observations_by_trace: %{}, warnings: []}
  end

  defp fetch_all_scores(api) do
    fetch_scores_page(api, nil, 0, %{})
  end

  defp fetch_scores_page(_api, _cursor, page, acc) when page >= @max_pages do
    {acc, ["scores pagination reached max page limit (#{@max_pages})"]}
  end

  defp fetch_scores_page(api, cursor, page, acc) do
    params =
      [
        limit: 100,
        name: @score_name,
        fields: "core,details,subject,annotation",
        fromTimestamp: @default_from_timestamp
      ]
      |> maybe_put_param(:cursor, cursor)

    case request(api, "/api/public/v3/scores", params) do
      {:ok, %{"data" => rows} = body} when is_list(rows) ->
        updated = Enum.reduce(rows, acc, &put_score/2)
        next_cursor = next_cursor(body["meta"])

        if is_binary(next_cursor) and next_cursor != "" do
          fetch_scores_page(api, next_cursor, page + 1, updated)
        else
          {updated, []}
        end

      {:ok, _unexpected} ->
        {acc, ["unexpected scores response"]}

      {:error, reason} ->
        {acc, ["scores fetch failed: #{inspect(reason)}"]}
    end
  end

  defp put_score(%{"name" => @score_name} = score, acc) do
    case score_trace_id(score) do
      trace_id when is_binary(trace_id) and trace_id != "" ->
        Map.put(acc, trace_id, %{
          "id" => score["id"],
          "value" => normalize_bool_score(score["value"]),
          "comment" => score["comment"],
          "timestamp" => score["timestamp"],
          "environment" => score["environment"]
        })

      _ ->
        acc
    end
  end

  defp put_score(_other, acc), do: acc

  defp score_trace_id(%{"subject" => %{"kind" => "trace", "id" => id}})
       when is_binary(id) and id != "",
       do: id

  defp score_trace_id(%{"traceId" => id}) when is_binary(id) and id != "", do: id

  defp score_trace_id(%{"id" => @score_id_prefix <> trace_id}) when trace_id != "",
    do: trace_id

  defp score_trace_id(_score), do: nil

  defp normalize_bool_score(val) when is_boolean(val), do: val
  defp normalize_bool_score(val) when is_number(val) and val == 1, do: true
  defp normalize_bool_score(val) when is_number(val) and val == 0, do: false
  defp normalize_bool_score(_other), do: nil

  defp fetch_trace_summary(trace_id, api) do
    case fetch_observations_page(api, trace_id, nil, 0, []) do
      {:ok, observations} -> {:ok, summarize_observations(observations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_observations_page(_api, _trace_id, _cursor, page, acc) when page >= @max_pages do
    {:ok, Enum.reverse(acc)}
  end

  defp fetch_observations_page(api, trace_id, cursor, page, acc) do
    params =
      [
        traceId: trace_id,
        fields: "core,basic,time,io,metadata,model,usage,prompt",
        fromStartTime: @default_from_timestamp,
        limit: 50
      ]
      |> maybe_put_param(:cursor, cursor)

    case request(api, "/api/public/v2/observations", params) do
      {:ok, %{"data" => observations} = body} when is_list(observations) ->
        updated = Enum.reverse(observations, acc)
        next = next_cursor(body["meta"])

        if is_binary(next) and next != "" do
          fetch_observations_page(api, trace_id, next, page + 1, updated)
        else
          {:ok, Enum.reverse(updated)}
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_observations_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize_observations(observations) do
    by_name = Map.new(observations, fn obs -> {obs["name"], obs} end)
    root = by_name["process-invoice"]
    extraction = by_name["extract-invoice"]
    verification = by_name["verify-extraction"]
    shadow = by_name["typesafe-shadow-verification"]

    %{
      "observation_count" => length(observations),
      "app_release" => root && get_in(root, ["metadata", "attributes.langfuse.release"]),
      "environment" => root && root["environment"],
      "extraction" => extraction && generation_summary(extraction),
      "verification" => verification && generation_summary(verification),
      "typesafe_shadow" => shadow && span_summary(shadow)
    }
  end

  defp generation_summary(obs) do
    usage = obs["usageDetails"] || %{}

    %{
      "model" => obs["providedModelName"] || obs["model"],
      "prompt_name" => blank_to_nil(obs["promptName"]),
      "prompt_version" => obs["promptVersion"],
      "latency_s" => obs["latency"],
      "cost" => obs["totalCost"],
      "finish_reason" => get_in(obs, ["metadata", "finish_reason"]),
      "usage" => compact_usage(usage)
    }
    |> compact_map()
  end

  defp span_summary(obs) do
    %{
      "model" => obs["providedModelName"] || obs["model"],
      "latency_s" => obs["latency"]
    }
    |> compact_map()
  end

  defp compact_usage(usage) when is_map(usage) do
    %{
      "input_tokens" => usage["input"],
      "output_tokens" => usage["output"],
      "total_tokens" => usage["total"]
    }
    |> compact_map()
    |> case do
      empty when map_size(empty) == 0 -> nil
      non_empty -> non_empty
    end
  end

  defp compact_usage(_other), do: nil

  defp request(api, path, params) do
    req_opts =
      api.req_options
      |> Keyword.merge(
        params: params,
        headers: [
          {"authorization", basic_auth(api.public_key, api.secret_key)},
          {"accept", "application/json"}
        ]
      )

    case Req.get(api.base_url <> path, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_config(opts) do
    config = Keyword.merge(Application.get_env(:zaimu_tomo, :langfuse, []), opts)
    base_url = Keyword.get(config, :base_url)
    public_key = Keyword.get(config, :public_key)
    secret_key = Keyword.get(config, :secret_key)

    if Enum.all?([base_url, public_key, secret_key], &(is_binary(&1) and &1 != "")) do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         public_key: public_key,
         secret_key: secret_key,
         req_options: Keyword.get(config, :req_options, [])
       }}
    else
      {:error, :langfuse_not_configured}
    end
  end

  defp basic_auth(public_key, secret_key),
    do: "Basic " <> Base.encode64("#{public_key}:#{secret_key}")

  defp next_cursor(%{"cursor" => cursor}) when is_binary(cursor), do: cursor
  defp next_cursor(%{"nextCursor" => cursor}) when is_binary(cursor), do: cursor
  defp next_cursor(_meta), do: nil

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Keyword.put(params, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp compact_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
