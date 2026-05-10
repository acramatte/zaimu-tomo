defmodule ZaimuTomo.Repo.Migrations.CascadeDeleteReviewDecisionsWithExtractedContent do
  use Ecto.Migration

  def change do
    alter table(:review_decisions) do
      modify :extracted_content_id,
             references(:extracted_content, on_delete: :delete_all),
             from: references(:extracted_content, on_delete: :nothing),
             null: false
    end
  end
end
