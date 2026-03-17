defmodule ZaimuTomoWeb.ExtractedContentController do
  use ZaimuTomoWeb, :controller

  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext

  @doc """
  Gets extracted content for a document
  """
  def index(conn, %{"document_id" => document_id}) do
    extractions = ExtractedContentContext.get_by_document(document_id)
    json(conn, %{data: extractions})
  end

  @doc """
  Gets the latest extraction for a document
  """
  def show(conn, %{"document_id" => document_id}) do
    extraction = ExtractedContentContext.get_latest_by_document(document_id)

    case extraction do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found", message: "No extracted content found for document #{document_id}"})

      _ ->
        json(conn, %{data: extraction})
    end
  end

  @doc """
  Lists extracted content with filters
  """
  def list(conn, params) do
    {extractions, meta} = ExtractedContentContext.list_extracted_content(params)
    json(conn, %{data: extractions, meta: meta})
  end

  @doc """
  Retries a failed extraction
  """
  def retry(conn, %{"id" => id}, params) do
    max_attempts = params["max_attempts"] || 3

    case ExtractedContentContext.retry_extraction(id, max_attempts) do
      {:ok, result} ->
        conn
        |> put_status(:accepted)
        |> json(%{data: result})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Cannot retry extraction", details: reason})
    end
  end
end
