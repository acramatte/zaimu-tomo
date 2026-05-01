defmodule ZaimuTomo.Repo.Migrations.CreateReviewDecisions do
  use Ecto.Migration

  def change do
    create table(:review_decisions) do
      add :extracted_content_id, references(:extracted_content, on_delete: :nothing), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :review_status, :string, default: "pending", null: false
      add :decision_type, :string, null: false
      add :decision_data, :map
      add :review_notes, :string, limit: 1000
      add :original_data, :map
      add :review_completed_at, :naive_datetime
      add :status, :string, default: "pending", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:review_decisions, [:extracted_content_id])
    create index(:review_decisions, [:user_id])
    create index(:review_decisions, [:review_status])
    create index(:review_decisions, [:extracted_content_id, :review_status])
  end
end
