defmodule ZaimuTomo.Repo.Migrations.CreateExtractedContentTable do
  use Ecto.Migration

  def change do
    create table(:extracted_content) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :extracted_data, :map, null: false
      add :status, :string, null: false
      add :error_details, :map
      add :analysis, :map

      timestamps(type: :utc_datetime)
    end

    create index(:extracted_content, [:document_id])
    create index(:extracted_content, [:status])
    create index(:extracted_content, [:inserted_at])
  end
end
