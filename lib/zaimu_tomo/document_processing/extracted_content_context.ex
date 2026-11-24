defmodule ZaimuTomo.DocumentProcessing.ExtractedContentContext do
  @moduledoc """
  Context for managing extracted content from OCR/LLM processing.
  """

  import Ecto.Query
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Repo

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
    query =
      from ec in ExtractedContent,
        where: ec.id == ^extraction_id,
        limit: 1

    Repo.one(query)
  end

  @doc """
  Persists a TypeSafe shadow result without replacing authoritative verification.

  Holds the row lock that `record_verification/2` takes, so the two jobs never
  overwrite each other's keys in `analysis`.
  """
  @spec put_typesafe_shadow(pos_integer(), map()) ::
          {:ok, ExtractedContent.t()} | {:error, term()}
  def put_typesafe_shadow(extraction_id, shadow) when is_map(shadow) do
    Repo.transact(fn ->
      case lock(extraction_id) do
        %ExtractedContent{} = content ->
          content
          |> Ecto.Changeset.change(
            analysis: put_verification_detail(content, %{"typesafe_shadow" => shadow})
          )
          |> Repo.update()

        nil ->
          {:error, :extracted_content_not_found}
      end
    end)
  end

  @doc """
  Records the verifier's result on a pending extraction, once.

  The only writer that moves `verification_status` off `pending`. `result`
  holds the end state under `"status"` and the detail to keep under
  `analysis["verification"]` (reason, field issues, error code, attempts,
  verifier model, prompt version). The row is locked while it is checked and
  written, so a second writer finds it decided and gets
  `{:error, :already_recorded}`; a deleted row is `{:error, :not_found}`.
  A recorded result is broadcast as `:verified`.
  """
  @spec record_verification(pos_integer(), map()) ::
          {:ok, ExtractedContent.t()} | {:error, :not_found | :already_recorded}
  def record_verification(extraction_id, %{"status" => status} = result) do
    Repo.transact(fn ->
      case lock(extraction_id) do
        nil ->
          {:error, :not_found}

        %ExtractedContent{verification_status: "pending"} = content ->
          update_verification(content, status, Map.delete(result, "status"))

        %ExtractedContent{} ->
          {:error, :already_recorded}
      end
    end)
    |> tap(fn
      {:ok, content} -> broadcast_verified(content)
      _error -> :ok
    end)
  end

  # The trigger refuses a move the pending check above did not see, which the
  # changeset reports as a constraint error.
  defp update_verification(content, status, detail) do
    content
    |> ExtractedContent.verification_changeset(status, put_verification_detail(content, detail))
    |> Repo.update()
    |> case do
      {:ok, content} -> {:ok, content}
      {:error, _changeset} -> {:error, :already_recorded}
    end
  end

  defp lock(extraction_id) do
    Repo.one(from ec in ExtractedContent, where: ec.id == ^extraction_id, lock: "FOR UPDATE")
  end

  defp put_verification_detail(content, detail) do
    analysis = content.analysis || %{}
    verification = Map.get(analysis, "verification") || %{}
    Map.put(analysis, "verification", Map.merge(verification, detail))
  end

  defp broadcast_verified(%ExtractedContent{user_id: nil}), do: :ok

  defp broadcast_verified(content) do
    DocumentProcessing.broadcast_event(:verified, content.user_id, %{
      document_id: content.document_id,
      extraction_id: content.id,
      user_id: content.user_id,
      status: content.verification_status
    })
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
end
