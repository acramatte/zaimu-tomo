defmodule ZaimuTomo.Storage.Migration do
  @moduledoc """
  Copies legacy document files into the configured object store without changing
  the document records that already reference their portable object keys.
  """

  alias ZaimuTomo.Documents
  alias ZaimuTomo.Storage

  @type missing_source :: %{object_key: String.t(), path: Path.t()}
  @type failure :: %{object_key: String.t(), operation: atom(), reason: term()}

  @type summary :: %{
          uploaded: non_neg_integer(),
          skipped_existing: non_neg_integer(),
          missing_sources: [missing_source()],
          failures: [failure()]
        }

  @spec migrate(Path.t()) :: {:ok, summary()} | {:error, summary()}
  def migrate(source_dir) when is_binary(source_dir) do
    summary =
      Documents.list_document_object_keys()
      |> Enum.reduce(empty_summary(), &migrate_object(&1, source_dir, &2))
      |> finalize_summary()

    result(summary)
  end

  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    [
      "Storage migration summary: uploaded=#{summary.uploaded} " <>
        "skipped-existing=#{summary.skipped_existing} " <>
        "missing-source=#{length(summary.missing_sources)} failed=#{length(summary.failures)}"
      | Enum.map(summary.missing_sources, &format_missing_source/1) ++
          Enum.map(summary.failures, &format_failure/1)
    ]
    |> Enum.join("\n")
  end

  defp migrate_object(object_key, source_dir, summary) do
    case Storage.head_object(object_key) do
      :ok ->
        %{summary | skipped_existing: summary.skipped_existing + 1}

      {:error, :not_found} ->
        upload_missing_object(object_key, source_dir, summary)

      {:error, reason} ->
        add_failure(summary, object_key, :head, reason)
    end
  end

  defp upload_missing_object(object_key, source_dir, summary) do
    source_path = Path.join(source_dir, Path.basename(object_key))

    case File.read(source_path) do
      {:ok, body} ->
        case Storage.put_object(object_key, body) do
          {:ok, ^object_key} ->
            %{summary | uploaded: summary.uploaded + 1}

          {:ok, returned_key} ->
            add_failure(summary, object_key, :put, {:unexpected_key, returned_key})

          {:error, reason} ->
            add_failure(summary, object_key, :put, reason)
        end

      {:error, :enoent} ->
        %{
          summary
          | missing_sources: [
              %{object_key: object_key, path: source_path} | summary.missing_sources
            ]
        }

      {:error, reason} ->
        add_failure(summary, object_key, :read_source, reason)
    end
  end

  defp empty_summary do
    %{uploaded: 0, skipped_existing: 0, missing_sources: [], failures: []}
  end

  defp add_failure(summary, object_key, operation, reason) do
    %{
      summary
      | failures: [
          %{object_key: object_key, operation: operation, reason: reason} | summary.failures
        ]
    }
  end

  defp result(%{missing_sources: [], failures: []} = summary), do: {:ok, summary}
  defp result(summary), do: {:error, summary}

  defp finalize_summary(summary) do
    %{
      summary
      | missing_sources: Enum.reverse(summary.missing_sources),
        failures: Enum.reverse(summary.failures)
    }
  end

  defp format_missing_source(%{object_key: object_key, path: path}) do
    "Missing source: #{path} for #{object_key}"
  end

  defp format_failure(%{object_key: object_key, operation: operation, reason: reason}) do
    "Failure: #{operation} for #{object_key}: #{inspect(reason)}"
  end
end
