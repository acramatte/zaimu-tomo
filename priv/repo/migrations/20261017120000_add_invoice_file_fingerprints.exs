defmodule ZaimuTomo.Repo.Migrations.AddInvoiceFileFingerprints do
  use Ecto.Migration

  @doc """
  Adds exact-byte SHA-256 fingerprints for uploaded documents and the
  posting-time snapshot copied to journal entries.

  The partial unique index allows one unconfirmed posting per file per user.
  Every existing digest is null when the columns are added, so the index can
  never collide here; `mix zaimu_tomo.backfill_document_fingerprints` fills
  historical rows afterwards through the storage facade. This migration stays
  database-only.
  """
  def change do
    alter table(:documents) do
      add :content_sha256, :string, size: 64
    end

    alter table(:journal_entries) do
      add :source_document_sha256, :string, size: 64
      add :source_file_reuse_confirmed, :boolean, null: false, default: false
    end

    create unique_index(:journal_entries, [:user_id, :source_document_sha256],
             where: "source_document_sha256 IS NOT NULL AND NOT source_file_reuse_confirmed",
             name: :journal_entries_user_source_document_sha256_unique_index
           )
  end
end
