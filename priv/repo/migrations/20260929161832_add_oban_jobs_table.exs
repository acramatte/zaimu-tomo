defmodule ZaimuTomo.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Pin the version shipped by the installed Oban (Oban.Migrations.Postgres
  # .current_version/0 in deps is 14) so a later Oban bump never silently
  # changes what this migration does.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
