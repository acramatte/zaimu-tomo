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
  Gets extracted content by ID.

  ## Parameters
    - extraction_id: ID of the extracted content record

  ## Returns
    - %ExtractedContent{} or nil
  """
  def get_by_id(extraction_id) do
    query = from ec in ExtractedContent,
            where: ec.id == ^extraction_id,
            limit: 1

    Repo.one(query)
  end

  @doc """
  Persists a TypeSafe shadow result without replacing authoritative verification.
  """
  @spec put_typesafe_shadow(pos_integer(), map()) ::
          {:ok, ExtractedContent.t()} | {:error, term()}
  def put_typesafe_shadow(extraction_id, shadow) when is_map(shadow) do
    case get_by_id(extraction_id) do
      %ExtractedContent{} = content ->
        analysis = content.analysis || %{}
        verification = Map.get(analysis, "verification", %{})

        updated_analysis =
          Map.put(analysis, "verification", Map.put(verification, "typesafe_shadow", shadow))

        content
        |> Ecto.Changeset.change(analysis: updated_analysis)
        |> Repo.update()

      nil ->
        {:error, :extracted_content_not_found}
    end
  end

  @doc """
  Gets the latest extraction for a document.

  ## Parameters
    - document_id: ID of the document

  ## Returns
    - %ExtractedContent{} or nil
  """
  def get_latest_by_document(document_id) do
    query = from ec in ExtractedContent,
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
end
