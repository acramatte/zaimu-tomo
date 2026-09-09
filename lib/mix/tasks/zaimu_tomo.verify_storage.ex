defmodule Mix.Tasks.ZaimuTomo.VerifyStorage do
  @moduledoc """
  HEADs every stored object key to verify it exists in the object store.

      mix zaimu_tomo.verify_storage
  """
  @shortdoc "Verifies that every document object key exists in storage"

  use Mix.Task

  alias ZaimuTomo.Release

  @impl Mix.Task
  def run([]), do: Release.verify_storage!()

  def run(_args) do
    Mix.raise("usage: mix zaimu_tomo.verify_storage")
  end
end
