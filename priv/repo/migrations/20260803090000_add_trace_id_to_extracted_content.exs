defmodule ZaimuTomo.Repo.Migrations.AddTraceIdToExtractedContent do
  use Ecto.Migration

  def change do
    alter table(:extracted_content) do
      add :trace_id, :string
    end
  end
end
