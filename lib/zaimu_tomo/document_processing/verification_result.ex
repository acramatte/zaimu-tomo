defmodule ZaimuTomo.DocumentProcessing.VerificationResult do
  @moduledoc """
  Structured result returned by the LLM verification step.

  The verifier explains whether extracted invoice fields are grounded in the OCR
  markdown and why the extraction may need human review or rejection.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(verified needs_review rejected)

  @primary_key false
  embedded_schema do
    field :status, :string
    field :reason, :string
    field :field_issues, :string
    field :raw_response, :map
  end

  @fields [:status, :reason, :field_issues, :raw_response]
  @required_fields [:status, :reason]

  @spec parse(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def parse(attrs) when is_map(attrs) do
    attrs
    |> put_raw_response()
    |> changeset()
    |> apply_action(:parse)
    |> case do
      {:ok, result} -> {:ok, to_map(result)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> update_change(:status, &normalize_status/1)
    |> update_change(:reason, &String.trim/1)
    |> update_change(:field_issues, &String.trim/1)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end

  defp put_raw_response(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put_new("raw_response", attrs)
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalize_status(status), do: status

  defp to_map(%__MODULE__{} = result) do
    %{
      "status" => result.status,
      "reason" => result.reason,
      "raw_response" => result.raw_response
    }
    |> maybe_put("field_issues", result.field_issues)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
