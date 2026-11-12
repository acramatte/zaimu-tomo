defmodule ZaimuTomo.Repo.Migrations.AddOneLiveOcrJobPerDocumentIndex do
  use Ecto.Migration

  def change do
    create unique_index(:oban_jobs, ["(args->>'document_id')"],
             name: :oban_jobs_one_live_ocr_job_per_document,
             where:
               "worker = 'ZaimuTomo.DocumentProcessing.OCRJob' " <>
                 "AND state IN ('available', 'scheduled', 'executing', 'retryable')"
           )
  end
end
