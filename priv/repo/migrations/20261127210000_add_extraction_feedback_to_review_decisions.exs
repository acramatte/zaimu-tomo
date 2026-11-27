defmodule ZaimuTomo.Repo.Migrations.AddExtractionFeedbackToReviewDecisions do
  use Ecto.Migration

  def change do
    alter table(:review_decisions) do
      add :extraction_feedback, :boolean
    end
  end
end
