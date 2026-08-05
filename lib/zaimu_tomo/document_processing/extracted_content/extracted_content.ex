defmodule ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.DocumentProcessing.ExtractedData

  schema "extracted_content" do
    embeds_one :extracted_data, ExtractedData
    field :raw_llm_response, :map
    field :status, :string
    field :error_details, :map
    field :analysis, :map
    field :trace_id, :string

    belongs_to :document, Document
    belongs_to :user, ZaimuTomo.Accounts.User
    has_one :review_decision, ZaimuTomo.Review.ReviewDecision

    timestamps()
  end

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
    |> maybe_cast_extracted_data(attrs)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:user_id)
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
