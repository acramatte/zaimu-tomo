defmodule Mix.Tasks.ZaimuTomo.MigrateToS3 do
  @shortdoc "Copies legacy document files into the configured object store"

  use Mix.Task

  alias ZaimuTomo.Release

  @impl Mix.Task
  def run(args) do
    {options, remaining, invalid} = OptionParser.parse(args, strict: [source_dir: :string])

    case {options[:source_dir], remaining, invalid} do
      {source_dir, [], []} when is_binary(source_dir) ->
        Release.migrate_to_s3!(source_dir)

      _ ->
        Mix.raise("usage: mix zaimu_tomo.migrate_to_s3 --source-dir PATH")
    end
  end
end
