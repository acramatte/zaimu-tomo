defmodule ZaimuTomo.Repo.Migrations.AddUserIdToExtractedContent do
  use Ecto.Migration

  def change do
    alter table(:extracted_content) do
      add :user_id, references(:users, on_delete: :nothing), null: false
    end

    create index(:extracted_content, [:user_id])
  end
end
