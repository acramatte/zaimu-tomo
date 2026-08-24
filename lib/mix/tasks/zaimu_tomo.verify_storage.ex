defmodule Mix.Tasks.ZaimuTomo.VerifyStorage do
  @shortdoc "Verifies that every document object key exists in storage"

  use Mix.Task

  alias ZaimuTomo.Release

  @impl Mix.Task
  def run([]), do: Release.verify_storage!()

  def run(_args) do
    Mix.raise("usage: mix zaimu_tomo.verify_storage")
  end
end
