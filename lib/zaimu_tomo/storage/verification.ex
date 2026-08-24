defmodule ZaimuTomo.Storage.Verification do
  @moduledoc """
  Verifies that every document record has a corresponding object in the
  configured storage provider.
  """

  alias ZaimuTomo.Documents
  alias ZaimuTomo.Storage

  @type failure :: %{object_key: String.t(), reason: term()}

  @type summary :: %{
          present: non_neg_integer(),
          missing: [String.t()],
          failures: [failure()]
        }

  @spec verify() :: {:ok, summary()} | {:error, summary()}
  def verify do
    summary =
      Documents.list_document_object_keys()
      |> Enum.reduce(empty_summary(), &verify_object/2)
      |> finalize_summary()

    result(summary)
  end

  @spec format_summary(summary()) :: String.t()
  def format_summary(summary) do
    [
      "Storage verification summary: present=#{summary.present} " <>
        "missing=#{length(summary.missing)} failed=#{length(summary.failures)}"
      | Enum.map(summary.missing, &"Missing object: #{&1}") ++
          Enum.map(summary.failures, &format_failure/1)
    ]
    |> Enum.join("\n")
  end

  defp verify_object(object_key, summary) do
    case Storage.head_object(object_key) do
      :ok ->
        %{summary | present: summary.present + 1}

      {:error, :not_found} ->
        %{summary | missing: [object_key | summary.missing]}

      {:error, reason} ->
        %{summary | failures: [%{object_key: object_key, reason: reason} | summary.failures]}
    end
  end

  defp empty_summary, do: %{present: 0, missing: [], failures: []}
  defp result(%{missing: [], failures: []} = summary), do: {:ok, summary}
  defp result(summary), do: {:error, summary}

  defp finalize_summary(summary) do
    %{summary | missing: Enum.reverse(summary.missing), failures: Enum.reverse(summary.failures)}
  end

  defp format_failure(%{object_key: object_key, reason: reason}) do
    "Failure: HEAD for #{object_key}: #{inspect(reason)}"
  end
end
