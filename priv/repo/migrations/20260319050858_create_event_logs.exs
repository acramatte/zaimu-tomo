defmodule ZaimuTomo.Repo.Migrations.CreateEventLogs do
  use Ecto.Migration

  def change do
    create table(:event_logs) do
      add :event_type, :string, null: false
      add :invoice_id, :string
      add :user_id, references(:users, on_delete: :nothing)
      add :metadata, :map, null: false
      add :status, :string, default: "pending", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:event_logs, [:event_type])
    create index(:event_logs, [:invoice_id])
    create index(:event_logs, [:user_id])
    create index(:event_logs, [:status])
  end
end
