defmodule ZaimuTomo.Repo.Migrations.AddRejectionReasonToReviewDecisions do
  use Ecto.Migration

  def change do
    alter table(:review_decisions) do
      add :rejection_reason, :string, limit: 1000
    end
  end
end
