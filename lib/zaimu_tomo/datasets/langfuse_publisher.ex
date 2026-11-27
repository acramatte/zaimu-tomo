defmodule ZaimuTomo.Datasets.LangfusePublisher do
  @moduledoc """
  Publishes exported evaluation JSONL files (`eval/representative.jsonl` or
  `eval/challenge.jsonl`) into Langfuse Datasets over `Req`.

  Every item receives a deterministic ID (`"<dataset>-doc-<document_id>"`) so
  repeated runs upsert cleanly without duplicates. Private fields
  (`content_sha256`, review comments, rejection reasons) are never sent to
  Langfuse.
  """

  alias ZaimuTomo.Storage

  @valid_tasks ~w(extraction verification)

  @type summary :: %{
          dataset_name: String.t(),
          task: String.t(),
          dry_run: boolean(),
          total: non_neg_integer(),
          published: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Publishes items from `:input` (local path) or `:s3_key` (object key in
  `ZaimuTomo.Storage`, e.g. `"datasets/v001/exports/eval/challenge.jsonl"`) into
  the Langfuse dataset named `:dataset`.

  ## Options

    * `:input` — local path to `eval/representative.jsonl` or
      `eval/challenge.jsonl` (required unless `:s3_key` is set).
    * `:s3_key` — S3 key of an exported `eval/*.jsonl` object (required unless
      `:input` is set).
    * `:dataset` (required) — Langfuse dataset name, e.g.
      `"invoice-extraction-eval-v001"`.
    * `:task` — `"extraction"` (default) or `"verification"`.
    * `:description` — optional dataset description.
    * `:dry_run` — when `true`, validates inputs and builds payloads without
      making HTTP requests (default `false`).
    * `:langfuse_opts` — optional overrides (`base_url`, `public_key`,
      `secret_key`, `req_options`) for testing.
  """
  @spec publish(keyword()) :: {:ok, summary()} | {:error, term()}
  def publish(opts) when is_list(opts) do
    with {:ok, source} <- resolve_source(opts),
         {:ok, dataset_name} <- fetch_required(opts, :dataset, :missing_dataset),
         {:ok, task} <- validate_task(Keyword.get(opts, :task, "extraction")),
         {:ok, rows} <- load_jsonl(source) do
      dry_run? = Keyword.get(opts, :dry_run, false)
      payloads = build_item_payloads(rows, dataset_name, task)
      skipped = length(rows) - length(payloads)

      if dry_run? do
        {:ok, build_summary(dataset_name, task, true, length(rows), 0, skipped)}
      else
        send_to_langfuse(dataset_name, task, payloads, length(rows), skipped, opts)
      end
    end
  end

  @doc "Formats a publish summary for CLI / release output."
  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    mode = if summary.dry_run, do: " (dry run)", else: ""

    "Langfuse dataset #{summary.dataset_name} [#{summary.task}]#{mode}: " <>
      "published=#{summary.published}, skipped=#{summary.skipped}, total=#{summary.total}"
  end

  defp send_to_langfuse(dataset_name, task, payloads, total, skipped, opts) do
    langfuse_opts = Keyword.get(opts, :langfuse_opts, [])

    with {:ok, api} <- api_config(langfuse_opts),
         :ok <- ensure_dataset(api, dataset_name, task, Keyword.get(opts, :description)),
         {:ok, published} <- upsert_items(api, payloads) do
      {:ok, build_summary(dataset_name, task, false, total, published, skipped)}
    end
  end

  defp ensure_dataset(api, name, task, description) do
    body =
      %{
        "name" => name,
        "description" => description || "ZaimuTomo #{task} evaluation dataset",
        "metadata" => %{"source" => "zaimu_tomo", "task" => task}
      }

    case post(api, "/api/public/v2/datasets", body) do
      {:ok, _resp} -> :ok
      {:error, reason} -> {:error, {:dataset_create_failed, reason}}
    end
  end

  defp upsert_items(api, payloads) do
    Enum.reduce_while(payloads, {:ok, 0}, fn payload, {:ok, count} ->
      case post(api, "/api/public/dataset-items", payload) do
        {:ok, _resp} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {:dataset_item_failed, payload["id"], reason}}}
      end
    end)
  end

  defp build_item_payloads(rows, dataset_name, task) do
    rows
    |> Enum.map(&item_payload(&1, dataset_name, task))
    |> Enum.reject(&is_nil/1)
  end

  defp item_payload(row, dataset_name, "extraction") do
    if is_map(row["ground_truth"]) and is_binary(row["ocr_markdown"]) do
      base_payload(row, dataset_name, %{
        "input" => %{
          "document_id" => row["document_id"],
          "currency_hint" => row["currency_hint"],
          "ocr_markdown" => row["ocr_markdown"]
        },
        "expectedOutput" => row["ground_truth"]
      })
    end
  end

  defp item_payload(row, dataset_name, "verification") do
    if is_map(row["candidate_extraction"]) and is_binary(row["ocr_markdown"]) do
      base_payload(row, dataset_name, %{
        "input" => %{
          "document_id" => row["document_id"],
          "currency_hint" => row["currency_hint"],
          "ocr_markdown" => row["ocr_markdown"],
          "extracted" => row["candidate_extraction"]
        },
        "expectedOutput" => %{
          "status" => row["expected_verdict"],
          "field_issues" => Enum.join(row["expected_field_issues"] || [], ",")
        }
      })
    end
  end

  defp base_payload(row, dataset_name, io_fields) do
    %{
      "id" => "#{dataset_name}-doc-#{row["document_id"]}",
      "datasetName" => dataset_name,
      "metadata" => %{
        "document_id" => row["document_id"],
        "split" => row["split"],
        "challenge_eval" => row["challenge_eval"],
        "label_quality" => row["label_quality"],
        "human_thumbs" => row["human_thumbs"],
        "ocr_faithful" => row["ocr_faithful"],
        "error_tags" => row["error_tags"] || []
      }
    }
    |> Map.merge(io_fields)
    |> maybe_put_trace_id(row["trace_id"])
  end

  defp maybe_put_trace_id(payload, trace_id) when is_binary(trace_id) and trace_id != "",
    do: Map.put(payload, "sourceTraceId", trace_id)

  defp maybe_put_trace_id(payload, _trace_id), do: payload

  defp post(api, path, body) do
    req_opts =
      api.req_options
      |> Keyword.merge(
        json: body,
        headers: [
          {"authorization", basic_auth(api.public_key, api.secret_key)},
          {"accept", "application/json"}
        ]
      )

    case Req.post(api.base_url <> path, req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
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

  defp fetch_required(opts, key, error) do
    case Keyword.get(opts, key) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _other -> {:error, error}
    end
  end

  defp validate_task(task) when task in @valid_tasks, do: {:ok, task}
  defp validate_task(task), do: {:error, {:invalid_task, task}}

  defp resolve_source(opts) do
    input = Keyword.get(opts, :input)
    s3_key = Keyword.get(opts, :s3_key)

    cond do
      is_binary(s3_key) and s3_key != "" -> {:ok, {:s3, s3_key}}
      is_binary(input) and input != "" -> {:ok, {:file, input}}
      true -> {:error, :missing_input}
    end
  end

  defp load_jsonl({:file, path}) do
    case File.read(path) do
      {:ok, content} -> decode_jsonl(content)
      {:error, reason} -> {:error, {:input_read_failed, path, reason}}
    end
  end

  defp load_jsonl({:s3, key}) do
    case Storage.read_object(key) do
      {:ok, content} -> decode_jsonl(content)
      {:error, reason} -> {:error, {:s3_read_failed, key, reason}}
    end
  end

  defp decode_jsonl(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &decode_line/2)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_line({line, line_no}, {:ok, acc}) do
    case String.trim(line) do
      "" -> {:cont, {:ok, acc}}
      trimmed -> decode_object(trimmed, line_no, acc)
    end
  end

  defp decode_object(line, line_no, acc) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:cont, {:ok, [map | acc]}}
      _other -> {:halt, {:error, {:invalid_jsonl, line_no}}}
    end
  end

  defp build_summary(dataset_name, task, dry_run?, total, published, skipped) do
    %{
      dataset_name: dataset_name,
      task: task,
      dry_run: dry_run?,
      total: total,
      published: published,
      skipped: skipped
    }
  end
end
