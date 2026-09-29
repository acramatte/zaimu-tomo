defmodule ZaimuTomo.Release do
  @moduledoc """
  Release helpers used by deployment tasks.
  """

  @app :zaimu_tomo

  alias ZaimuTomo.DocumentProcessing
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

  def recover_stuck_documents!(opts \\ []) do
    start_app()
    groups = DocumentProcessing.Recovery.list_stuck()
    Enum.each(groups, &print_stuck_group/1)

    dispatch_recovery(Keyword.get(opts, :confirm, false), groups)
  end

  defp dispatch_recovery(true, groups) do
    jobs = DocumentProcessing.Recovery.enqueue_stuck(groups)
    IO.puts("Enqueued #{length(jobs)} OCR jobs.")
    groups
  end

  defp dispatch_recovery(false, groups) do
    count = groups |> Enum.map(&length(&1.document_ids)) |> Enum.sum()
    IO.puts("Dry run: #{count} stuck documents — nothing enqueued.")
    IO.puts("Re-run with confirm: true (or CONFIRM=true) to enqueue.")
    groups
  end

  defp print_stuck_group(%{user_id: user_id, currency: currency, document_ids: document_ids}) do
    IO.puts("user #{user_id} (#{currency}): document ids #{Enum.join(document_ids, ", ")}")
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp start_app do
    load_app()

    # Eval nodes run maintenance only: no queues, no plugins, no leadership, so
    # a short-lived node never grabs a job and dies mid-run (leaving it orphaned
    # until Lifeline rescues it).
    oban = Application.fetch_env!(@app, Oban)

    Application.put_env(
      @app,
      Oban,
      Keyword.merge(oban, queues: false, plugins: false, peer: false)
    )

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
