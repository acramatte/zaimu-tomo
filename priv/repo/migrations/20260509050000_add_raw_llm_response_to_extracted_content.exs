defmodule ZaimuTomo.Repo.Migrations.AddRawLlmResponseToExtractedContent do
  use Ecto.Migration

  def change do
    alter table(:extracted_content) do
      add :raw_llm_response, :map
    end
  end
end
