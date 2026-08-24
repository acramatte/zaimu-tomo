defmodule ZaimuTomo.Release do
  @moduledoc """
  Release helpers used by deployment tasks.
  """

  @app :zaimu_tomo

  alias ZaimuTomo.Storage.{Migration, Verification}

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def migrate_to_s3!(source_dir) when is_binary(source_dir) do
    start_app()
    report_or_raise(Migration.migrate(source_dir), Migration)
  end

  def migrate_to_s3_from_env! do
    System.fetch_env!("SOURCE_DIR")
    |> migrate_to_s3!()
  end

  def verify_storage! do
    start_app()
    report_or_raise(Verification.verify(), Verification)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp start_app do
    case Application.ensure_all_started(@app) do
      {:ok, _started} -> :ok
      {:error, reason} -> raise "could not start #{@app}: #{inspect(reason)}"
    end
  end

  defp report_or_raise({status, summary}, formatter) do
    IO.puts(formatter.format_summary(summary))

    case status do
      :ok -> summary
      :error -> raise "storage maintenance command failed"
    end
  end
end
