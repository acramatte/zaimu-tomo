defmodule Mix.Tasks.ZaimuTomo.BackfillDocumentFingerprints do
  @moduledoc """
  Backfills SHA-256 fingerprints for existing documents and their journal
  entries. Idempotent and safe to run while the app is online; see
  `ZaimuTomo.Documents.FingerprintBackfill`.

  Exits non-zero while historical coverage is incomplete (missing or
  unreadable objects, or same-user collisions awaiting human review).

      mix zaimu_tomo.backfill_document_fingerprints
      mix zaimu_tomo.backfill_document_fingerprints --confirm-reuse 123 --confirm-reuse 456

  `--confirm-reuse ID` records a human decision that the reported later
  journal entry is a legitimate reuse of the same file (for example, a reused
  QR-bill); it is applied only to an entry that collides.
  """
  @shortdoc "Backfills exact-byte document fingerprints"

  use Mix.Task

  alias ZaimuTomo.Release

  @usage "usage: mix zaimu_tomo.backfill_document_fingerprints [--confirm-reuse ID]..."

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [confirm_reuse: [:integer, :keep]]) do
      {opts, [], []} ->
        Release.backfill_document_fingerprints!(
          confirm_reuse: Keyword.get_values(opts, :confirm_reuse)
        )

      _ ->
        Mix.raise(@usage)
    end
  end
end
