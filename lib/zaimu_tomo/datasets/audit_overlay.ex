defmodule ZaimuTomo.Datasets.AuditOverlay do
  @moduledoc """
  Loads an optional human-curated JSONL audit overlay (`audit_overlay.jsonl`)
  merged into canonical records during dataset builds.

  Each line is a JSON object keyed by integer `document_id`, with optional
  fields:

    * `"ocr_faithful"` — boolean indicating whether the OCR text accurately
      captured the source PDF/image fields.
    * `"error_tags"` — list of string error classification tags (for example
      `"subtotal_instead_of_total"`).
    * `"extracted_faithful"` — map of corrected invoice fields merged onto the
      canonical faithful ground truth.
    * `"quality"` — optional quality label (defaults to `"gold_audited"`).
  """

  @allowed_fields ~w(amount_to_pay_cents currency invoice_date invoice_number issuer reason_for_payment)

  @type entry :: %{
          optional(String.t()) => term()
        }

  @doc """
  Loads an overlay file into a `%{document_id => entry}` map. Returns `{:ok, %{}}`
  when `path` is `nil`.
  """
  @spec load(Path.t() | nil) :: {:ok, %{pos_integer() => entry()}} | {:error, term()}
  def load(nil), do: {:ok, %{}}

  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse_lines(content)
      {:error, reason} -> {:error, {:audit_overlay_read_failed, path, reason}}
    end
  end

  defp parse_lines(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, &reduce_line/2)
  end

  defp reduce_line({line, line_no}, {:ok, acc}) do
    case String.trim(line) do
      "" ->
        {:cont, {:ok, acc}}

      trimmed ->
        case parse_entry(trimmed, line_no) do
          {:ok, doc_id, entry} -> {:cont, {:ok, Map.put(acc, doc_id, entry)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp parse_entry(line, line_no) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(line),
         {:ok, doc_id} <- parse_doc_id(decoded["document_id"], line_no),
         {:ok, entry} <- validate_entry(decoded, line_no) do
      {:ok, doc_id, entry}
    else
      {:error, {:invalid_audit_overlay, _, _}} = error -> error
      _other -> {:error, {:invalid_audit_overlay, line_no, "expected a JSON object"}}
    end
  end

  defp parse_doc_id(id, _line_no) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_doc_id(_other, line_no),
    do: {:error, {:invalid_audit_overlay, line_no, "document_id must be a positive integer"}}

  defp validate_entry(map, line_no) do
    with :ok <- validate_optional_boolean(map["ocr_faithful"], "ocr_faithful", line_no),
         :ok <- validate_error_tags(map["error_tags"], line_no),
         :ok <- validate_extracted_faithful(map["extracted_faithful"], line_no) do
      {:ok,
       %{
         "ocr_faithful" => map["ocr_faithful"],
         "error_tags" => map["error_tags"] || [],
         "extracted_faithful" => map["extracted_faithful"],
         "quality" => map["quality"] || "gold_audited"
       }}
    end
  end

  defp validate_optional_boolean(nil, _field, _line_no), do: :ok
  defp validate_optional_boolean(val, _field, _line_no) when is_boolean(val), do: :ok

  defp validate_optional_boolean(_other, field, line_no),
    do: {:error, {:invalid_audit_overlay, line_no, "#{field} must be a boolean"}}

  defp validate_error_tags(nil, _line_no), do: :ok

  defp validate_error_tags(tags, line_no) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_audit_overlay, line_no, "error_tags must be a list of strings"}}
  end

  defp validate_error_tags(_other, line_no),
    do: {:error, {:invalid_audit_overlay, line_no, "error_tags must be a list of strings"}}

  defp validate_extracted_faithful(nil, _line_no), do: :ok

  defp validate_extracted_faithful(fields, line_no) when is_map(fields) do
    unknown = Map.keys(fields) -- @allowed_fields

    if unknown == [],
      do: :ok,
      else:
        {:error,
         {:invalid_audit_overlay, line_no,
          "unknown extracted_faithful fields: #{Enum.join(unknown, ", ")}"}}
  end

  defp validate_extracted_faithful(_other, line_no),
    do: {:error, {:invalid_audit_overlay, line_no, "extracted_faithful must be a JSON object"}}
end
