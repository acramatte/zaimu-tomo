defmodule ZaimuTomo.DocumentProcessing.ExtractedContentContext do
  @moduledoc """
  Context for managing extracted content from OCR/LLM processing.
  """

  import Ecto.Query
  alias ZaimuTomo.Repo
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

  @doc """
  Creates a new extracted content record.

  ## Parameters
    - attrs: Map containing extracted content data

  ## Returns
    - {:ok, %ExtractedContent{}} on success
    - {:error, changeset} on validation error
  """
  def create_extracted_content(attrs) do
    %ExtractedContent{}
    |> ExtractedContent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieves extracted content by document ID.

  ## Parameters
    - document_id: ID of the document
    - limit: Maximum number of results (default: 50)

  ## Returns
    - List of extracted content records
  """
  def get_by_document(document_id, limit \\ 50) do
    query =
      from ec in ExtractedContent,
        where: ec.document_id == ^document_id,
        order_by: [desc: :inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  @doc """
  Gets extracted content by ID.

  ## Parameters
    - extraction_id: ID of the extracted content record

  ## Returns
    - %ExtractedContent{} or nil
  """
  def get_by_id(extraction_id) do
    query =
      from ec in ExtractedContent,
        where: ec.id == ^extraction_id,
        limit: 1

    Repo.one(query)
  end

  @doc """
  Gets the latest extraction for a document.

  ## Parameters
    - document_id: ID of the document

  ## Returns
    - %ExtractedContent{} or nil
  """
  def get_latest_by_document(document_id) do
    query =
      from ec in ExtractedContent,
        where: ec.document_id == ^document_id,
        order_by: [desc: :inserted_at, desc: :id],
        limit: 1

    Repo.one(query)
  end

  def get_structured_data(content) when is_map(content) do
    # extracted_data is already a struct, just return it
    {:ok, content.extracted_data}
  end

  def get_response_data(content) do
    # Convert struct to map for API responses
    Map.from_struct(content.extracted_data)
  end

  def get_analysis(content) do
    content.analysis || %{}
  end

  # Combined response with data and analysis
  def get_full_response(content) do
    %{
      "data" => get_response_data(content),
      "analysis" => get_analysis(content),
      "status" => content.status,
      "extracted_at" => content.inserted_at
    }
  end

  # Get specific fields with type safety
  def get_invoice_amount(content) do
    content.extracted_data.amount_to_pay_cents
  end

  def get_invoice_date(content) do
    content.extracted_data.invoice_date
  end

  def get_invoice_number(content) do
    content.extracted_data.invoice_number
  end

  @doc """
  Lists extracted content with optional filters.

  ## Parameters
    - filters: Map of filter parameters
      - status: Filter by status
      - start_date: Start date filter
      - end_date: End date filter
      - limit: Maximum results (default: 50)

  ## Returns
    - Tuple with results and metadata
  """
  def list_extracted_content(filters \\ []) do
    query = from(ec in ExtractedContent)

    query = apply_filters(query, filters)

    limit = Keyword.get(filters, :limit, 50)
    query = order_by(query, desc: :inserted_at)
    query = limit(query, ^limit)

    results = Repo.all(query)
    total_count_query = from ec in ExtractedContent, select: count(ec.id)
    total_count = Repo.one(total_count_query)

    {results, %{total_count: total_count, limit: limit}}
  end

  @doc """
  Retries a failed extraction. Needs Implementation !

  ## Parameters
    - extraction_id: ID of the failed extraction
    - max_attempts: Maximum retry attempts (default: 3)

  ## Returns
    - {:ok, retry_info} or {:error, reason}
  """
  def retry_extraction(extraction_id, max_attempts \\ 3)
  def retry_extraction(_extraction_id, 0), do: {:error, :max_attempts_reached}

  def retry_extraction(extraction_id, _max_attempts),
    do: {:ok, %{status: "retry_scheduled", extraction_id: extraction_id}}

  defp apply_filters(query, filters) do
    query
    |> maybe_filter_status(filters)
    |> maybe_filter_date_range(filters)
  end

  defp maybe_filter_status(query, filters) do
    if status = filters[:status] do
      where(query, [ec], ec.status == ^status)
    else
      query
    end
  end

  defp maybe_filter_date_range(query, filters) do
    start_date = filters[:start_date]
    end_date = filters[:end_date]

    if start_date || end_date do
      start_date =
        start_date ||
          DateTime.utc_now()
          |> DateTime.to_naive()
          |> DateTime.shift(<<"1970-01-01">>, years: -100)

      end_date = end_date || DateTime.utc_now() |> DateTime.to_naive()

      where(
        query,
        [ec],
        ec.inserted_at >= ^start_date and
          ec.inserted_at <= ^end_date
      )
    else
      query
    end
  end
end
