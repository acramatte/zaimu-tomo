defmodule ZaimuTomo.Repo.Migrations.UniqueReviewDecisionPerExtraction do
  use Ecto.Migration

  def change do
    drop index(:review_decisions, [:extracted_content_id])
    create unique_index(:review_decisions, [:extracted_content_id])
  end
end
