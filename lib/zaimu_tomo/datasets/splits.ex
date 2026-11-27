defmodule ZaimuTomo.Datasets.Splits do
  @moduledoc """
  Deterministic, zero-leakage train/validation/test splitting for canonical
  invoice records.

  Documents that share either a normalized issuer or an exact source-file
  SHA-256 are merged into one connected component before splitting so the same
  issuer or recurring PDF template never spans training and evaluation sets.
  """

  @default_ratios %{train: 0.70, validation: 0.15, test: 0.15}
  @default_seed "zaimu-tomo-v1"
  @bucket_scale 10_000

  @type split_name :: String.t()
  @type ratios :: %{train: float(), validation: float(), test: float()}

  @doc """
  Normalizes an issuer name for grouping (trimmed, lowercased, collapsed
  whitespace). Returns `nil` for blank values.
  """
  @spec normalize_issuer(String.t() | nil) :: String.t() | nil
  def normalize_issuer(nil), do: nil

  def normalize_issuer(issuer) when is_binary(issuer) do
    case issuer |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ") do
      "" -> nil
      normalized -> normalized
    end
  end

  @doc """
  Assigns every record in `records` to `"train"`, `"validation"`, or `"test"`
  and sets `grouping["split"]` and `grouping["challenge_eval"]` on each record.

  Returns `{updated_records, splits_artifact}` where `splits_artifact` is ready
  to be JSON-encoded as `splits.json`.
  """
  @spec assign([map()], keyword()) :: {[map()], map()}
  def assign(records, opts \\ []) when is_list(records) do
    seed = Keyword.get(opts, :seed, @default_seed)
    ratios = Keyword.get(opts, :ratios, @default_ratios)
    version = Keyword.get(opts, :version)

    groups = build_groups(records)
    group_assignments = assign_groups(groups, ratios, seed)

    doc_to_split =
      for {group_key, doc_ids} <- groups,
          split = Map.fetch!(group_assignments, group_key),
          doc_id <- doc_ids,
          into: %{},
          do: {doc_id, split}

    updated_records =
      Enum.map(records, fn record ->
        doc_id = record["document_id"]
        split = Map.fetch!(doc_to_split, doc_id)
        challenge? = challenge_eval?(record)

        put_in(record, ["grouping"], %{
          "issuer_norm" => get_in(record, ["grouping", "issuer_norm"]),
          "split" => split,
          "challenge_eval" => challenge?
        })
      end)

    splits_artifact = %{
      "version" => version,
      "seed" => seed,
      "ratios" => %{
        "train" => ratios.train,
        "validation" => ratios.validation,
        "test" => ratios.test
      },
      "group_count" => length(groups),
      "split_counts" => count_by_split(updated_records),
      "challenge_eval_count" =>
        Enum.count(updated_records, &get_in(&1, ["grouping", "challenge_eval"])),
      "assignments" => Map.new(doc_to_split, fn {doc_id, split} -> {to_string(doc_id), split} end)
    }

    {updated_records, splits_artifact}
  end

  @doc """
  Returns true when a canonical record represents a known difficult case
  suitable for the challenge evaluation slice.
  """
  @spec challenge_eval?(map()) :: boolean()
  def challenge_eval?(record) when is_map(record) do
    label = record["label"] || %{}
    latest = record |> Map.get("processing_runs", []) |> List.last() || %{}

    label_flagged?(label) or run_flagged?(latest)
  end

  defp label_flagged?(label) do
    label["review_status"] == "amended" or
      label["human_thumbs"] == false or
      label["ocr_faithful"] == false or
      (label["error_tags"] || []) != []
  end

  defp run_flagged?(run) do
    get_in(run, ["verification", "status"]) in ["needs_review", "rejected", "verification_failed"] or
      get_in(run, ["typesafe_shadow", "status"]) == "needs_review"
  end

  # Union-find connected components over issuer_norm and content_sha256.
  defp build_groups(records) do
    keys_by_doc = Map.new(records, fn r -> {r["document_id"], doc_group_keys(r)} end)
    parent = build_union_find(keys_by_doc)

    records
    |> Enum.group_by(fn r ->
      first_key = hd(Map.fetch!(keys_by_doc, r["document_id"]))
      find_root(parent, first_key)
    end)
    |> Enum.map(fn {root, grouped_records} ->
      doc_ids = grouped_records |> Enum.map(& &1["document_id"]) |> Enum.sort()
      {root, doc_ids}
    end)
  end

  defp doc_group_keys(record) do
    issuer_key =
      case get_in(record, ["grouping", "issuer_norm"]) do
        issuer when is_binary(issuer) and issuer != "" -> "issuer:" <> issuer
        _ -> nil
      end

    sha_key =
      case get_in(record, ["document", "content_sha256"]) do
        sha when is_binary(sha) and sha != "" -> "sha:" <> sha
        _ -> nil
      end

    case Enum.reject([issuer_key, sha_key], &is_nil/1) do
      [] -> ["doc:#{record["document_id"]}"]
      keys -> keys
    end
  end

  defp build_union_find(keys_by_doc) do
    Enum.reduce(keys_by_doc, %{}, fn {_doc_id, [first | rest]}, parent ->
      parent = Map.put_new(parent, first, first)

      Enum.reduce(rest, parent, fn key, acc ->
        acc = Map.put_new(acc, key, key)
        union(acc, first, key)
      end)
    end)
  end

  defp find_root(parent, key) do
    case Map.get(parent, key, key) do
      ^key -> key
      next -> find_root(parent, next)
    end
  end

  defp union(parent, a, b) do
    ra = find_root(parent, a)
    rb = find_root(parent, b)

    cond do
      ra == rb -> parent
      ra < rb -> Map.put(parent, rb, ra)
      true -> Map.put(parent, ra, rb)
    end
  end

  # Pure hash-bucketing per group key ensures adding new documents in future
  # dataset versions never shifts an existing group from test/validation to train.
  defp assign_groups(groups, ratios, seed) do
    Map.new(groups, fn {key, _doc_ids} -> {key, bucket_for(key, ratios, seed)} end)
  end

  defp bucket_for(key, ratios, seed) do
    <<n::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, "#{seed}:#{key}")
    pos = rem(n, @bucket_scale) / @bucket_scale

    cond do
      pos < ratios.train -> "train"
      pos < ratios.train + ratios.validation -> "validation"
      true -> "test"
    end
  end

  defp count_by_split(records) do
    base = %{"train" => 0, "validation" => 0, "test" => 0}

    Enum.reduce(records, base, fn record, acc ->
      split = get_in(record, ["grouping", "split"])
      Map.update(acc, split, 1, &(&1 + 1))
    end)
  end
end
