defmodule ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document

  schema "extracted_content" do
    embeds_one :extracted_data, ExtractedData
    field :raw_llm_response, :map
    field :status, :string
    field :error_details, :map
    field :analysis, :map
    field :trace_id, :string
    field :verification_status, :string

    belongs_to :document, Document
    belongs_to :user, ZaimuTomo.Accounts.User
    has_one :review_decision, ZaimuTomo.Review.ReviewDecision

    timestamps()
  end

  @type t :: %__MODULE__{}

  @verification_end_states ~w(verified needs_review rejected verification_failed)

  @doc """
  The statuses a verification can end in. Only `verified` may ever count as a
  pass; `verification_failed` means a human checks the extraction.
  """
  def verification_end_states, do: @verification_end_states

  @doc """
  Builds a new extraction row. A success row starts its verification as
  `pending` and a failed row has none; the status is set here, never cast,
  and the database refuses any other start
  (`extracted_content_verification_initial_status_check`).
  """
  def changeset(extracted_content, attrs) do
    extracted_content
    |> cast(attrs, [
      :document_id,
      :user_id,
      :status,
      :raw_llm_response,
      :error_details,
      :analysis,
      :trace_id
    ])
    |> validate_required([:document_id, :status])
    |> validate_inclusion(:status, ["success", "failed"])
    |> put_initial_verification_status()
    |> maybe_cast_extracted_data(attrs)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Moves a pending verification to one of the end states, with its detail in
  `analysis["verification"]`. Only `ExtractedContentContext.record_verification/2`
  calls it, on a row it holds locked. The database refuses every other move
  (`extracted_content_verification_transition_check`).
  """
  def verification_changeset(%__MODULE__{} = extracted_content, status, analysis) do
    extracted_content
    |> change(verification_status: status, analysis: analysis)
    |> validate_inclusion(:verification_status, @verification_end_states)
    |> check_constraint(:verification_status,
      name: :extracted_content_verification_transition_check,
      message: "is already recorded"
    )
  end

  defp put_initial_verification_status(changeset) do
    case get_field(changeset, :status) do
      "success" -> put_change(changeset, :verification_status, "pending")
      _failed -> put_change(changeset, :verification_status, nil)
    end
  end

  defp maybe_cast_extracted_data(changeset, attrs) do
    case status_from_attrs(attrs) do
      "failed" ->
        put_embed(changeset, :extracted_data, %ExtractedData{})

      _ ->
        changeset
        |> cast_embed(:extracted_data, with: &ExtractedData.embedded_changeset/2)
        |> validate_embedded_data_size()
        |> validate_extracted_data_for_status()
    end
  end

  defp status_from_attrs(attrs), do: Map.get(attrs, :status) || Map.get(attrs, "status")

  defp validate_extracted_data_for_status(changeset) do
    status = get_field(changeset, :status)
    extracted_data = get_field(changeset, :extracted_data)

    case {status, extracted_data} do
      # If it failed, we don't care about the data
      {"failed", _} ->
        changeset

      # If it didn't fail, but the data is nil or an empty map, add an error
      {_, empty_data} when empty_data in [nil, %{}] ->
        add_error(changeset, :extracted_data, "is required for successful extractions")

      _ ->
        changeset
    end
  end

  defp validate_embedded_data_size(changeset) do
    extracted_data = get_field(changeset, :extracted_data)

    case extracted_data do
      nil ->
        changeset

      %ExtractedData{} = data ->
        size = byte_size(Jason.encode!(Map.from_struct(data)))

        if size <= 10_000_000 do
          changeset
        else
          add_error(changeset, :extracted_data, "exceeds maximum size of 10MB")
        end
    end
  end
end
