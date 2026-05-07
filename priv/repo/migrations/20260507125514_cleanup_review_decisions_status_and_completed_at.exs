defmodule ZaimuTomo.Repo.Migrations.CleanupReviewDecisionsStatusAndCompletedAt do
  use Ecto.Migration

  def change do
    alter table(:review_decisions) do
      remove :status
    end
  end
end
