defmodule ZaimuTomo.Repo.Migrations.AddOneLiveExtractJobPerStatementIndex do
  use Ecto.Migration

  def change do
    create unique_index(:oban_jobs, ["(args->>'statement_id')"],
             name: :oban_jobs_one_live_extract_job_per_statement,
             where:
               "worker = 'ZaimuTomo.Statements.ExtractJob' " <>
                 "AND state IN ('available', 'scheduled', 'executing', 'retryable')"
           )
  end
end
