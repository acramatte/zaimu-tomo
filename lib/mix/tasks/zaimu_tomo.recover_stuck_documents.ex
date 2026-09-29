defmodule Mix.Tasks.ZaimuTomo.RecoverStuckDocuments do
  @moduledoc """
  Enqueues fresh OCR runs for stuck documents (no extraction row, no live job).

  Dry run by default; enqueues only with --confirm.

      mix zaimu_tomo.recover_stuck_documents
      mix zaimu_tomo.recover_stuck_documents --confirm
  """
  @shortdoc "Recovers documents whose OCR processing run was lost"

  use Mix.Task
  alias ZaimuTomo.Release

  @impl Mix.Task
  def run([]), do: Release.recover_stuck_documents!()

  def run(["--confirm"]), do: Release.recover_stuck_documents!(confirm: true)

  def run(_args) do
    Mix.raise("usage: mix zaimu_tomo.recover_stuck_documents [--confirm]")
  end
end
