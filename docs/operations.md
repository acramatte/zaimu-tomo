# Operations runbook

Day-2 tasks for the production deployment described in
[deployment.md](deployment.md). Commands assume the Kamal secrets are exported
(`set -a; source .kamal/secrets; set +a`).

## Quick reference

| Task | Command |
|---|---|
| Remote IEx console | `kamal console` |
| Run migrations | `kamal migrate` |
| Roll back one migration | `kamal db_rollback` |
| App logs | `kamal app logs -f` |
| Find stuck documents (dry run) | `kamal recover_stuck_documents` |
| Re-enqueue stuck documents | `kamal app exec "bin/zaimu_tomo eval 'ZaimuTomo.Release.recover_stuck_documents!(confirm: true)'"` |
| Verify every stored object exists | `kamal verify_storage` |
| Backfill document fingerprints | `kamal backfill_document_fingerprints` |

Locally, the equivalents are `mix ecto.migrate`, `mix zaimu_tomo.recover_stuck_documents [--confirm]`, `mix zaimu_tomo.verify_storage`, and `mix zaimu_tomo.backfill_document_fingerprints [--confirm-reuse ID]...`.

## Document processing

### Watching jobs

OCR runs on the Oban `documents` queue and TypeSafe shadow runs on the `typesafe` queue.
There is no Oban Web UI. Inspect jobs from `kamal console`:

```elixir
import Ecto.Query
ZaimuTomo.Repo.all(from j in Oban.Job, where: j.state in ~w(available scheduled executing retryable),
  select: {j.id, j.queue, j.state, j.attempt, j.args})
```

Failed attempts are logged by `ZaimuTomo.ObanFailureLogger` as body-free
summaries. Terminal failures log `[OCR] Processing failed for document …`.
`oban_jobs.errors` holds the same bounded summaries, never OCR text.

### Stuck documents

A document is *stuck* when it has no extraction row and no live OCR job (for
example, a job was discarded or cancelled without recording a failure). Users
can retry stuck and failed documents from the UI. To sweep them in bulk:

1. Dry run: `kamal recover_stuck_documents` lists the stuck documents per user.
2. Enqueue: `kamal app exec "bin/zaimu_tomo eval 'ZaimuTomo.Release.recover_stuck_documents!(confirm: true)'"`
   (inside the container, `CONFIRM=true bin/recover_stuck_documents` does the same). This is idempotent, because Oban uniqueness prevents a second live job per document.

### Document fingerprint backfill

Uploads record a SHA-256 of their exact bytes (`documents.content_sha256`), and
postings copy it to `journal_entries.source_document_sha256`. Rows created
before the `20261017120000` migration have no fingerprint until this one-off
backfill reads their objects. The unique index exists before it runs, so it is
safe while the app stays online; no upload or approval pause is needed.

1. Run `kamal backfill_document_fingerprints`. It hashes every document with a
   null digest through the storage facade, then copies digests to journal
   entries one row at a time, oldest posting first. The report lists IDs and
   counts only, never bytes or digests. It exits non-zero while coverage is
   incomplete.
2. Read the report:
   - **Missing object / read failure:** the digest stays null; that document and
     its entries have no exact-file protection. Restore the object if a backup
     has it (then rerun), otherwise record the partial coverage.
   - **Collision:** two historical postings of the same user have identical
     bytes. The later entry stays null and is named with the entry it collides
     with. Nothing is deleted or merged. Review both entries in the ledger:
     a genuine duplicate is corrected through the normal ledger process; a
     legitimate reuse (for example, the same QR-bill for two periods) is
     confirmed by a human.
3. To record a human-confirmed reuse, rerun with the later entry's ID:
   `kamal app exec "bin/backfill_document_fingerprints <journal_entry_id> ..."`
   (locally, `mix zaimu_tomo.backfill_document_fingerprints --confirm-reuse <id>`).
   The entry gets its digest and `source_file_reuse_confirmed` in one update. An
   ID that does not collide is reported as unused and left unchanged.
4. Rerun after any resolution until it reports complete coverage, or until the
   only remaining rows are documented missing objects.

This is the only permitted update of an existing entry's fingerprint. If a
database-level immutability trigger on `journal_entries` is ever added, run the
backfill first or allow this update explicitly.

### Throttling

If the LLM provider rate-limits, set a lower `OBAN_DOCUMENTS_CONCURRENCY` (default 2)
or `TYPESAFE_MAX_CONCURRENCY` under `env.clear` in `config/deploy.yml` and redeploy. Locally, set
`OBAN_DOCUMENTS_CONCURRENCY=1` with a single-NPU FastFlowLM backend.

## Backups and restore

Data lives in two places that must be backed up **together and in order**:
RustFS objects first, then the PostgreSQL dump. Objects are created before rows
are inserted, and rows are deleted before objects. So an object export that is
older than the DB dump can contain only harmless orphan objects, never missing
ones.

Nightly, while document writes are quiet:

1. Export the bucket through the S3 API with `rclone copy --checksum --immutable` to a **new date-stamped path** on off-host storage, then `rclone check --checksum`. Use an rclone S3 remote with `provider = Other` and `force_path_style = true`, a read-only credential, and the RustFS region. Don't snapshot RustFS's `/data` directory while it is live.
2. `pg_dump` the production database to off-host storage.
3. Run `kamal verify_storage`.

Restore (also used for periodic restore drills on a scratch environment):
restore the object export first, then the Postgres dump, then run `bin/verify_storage`.
It must report zero missing and zero failed.

Backup credentials and destinations are not kept in the repository.

## Legacy upload volume

Before August 2026, document bytes lived in `priv/uploads` on a Docker volume
(`zaimu_tomo_uploads`). The migration release copied them to RustFS with
`bin/migrate_to_s3` (HEAD first, upload only missing objects, never overwrite or
delete) and verified them with `bin/verify_storage`. The volume mount in
`config/deploy.yml` and the directory in the `Dockerfile` remain until a restore
check is recorded. After that, remove both in a cleanup release and update
[architecture.md §11](architecture.md#11-risks-and-technical-debt).

## Database access

The Postgres accessory's host port listens only on loopback. Use an SSH tunnel
from the operator machine, or `kamal accessory exec db "psql -U zaimu_tomo zaimu_tomo_prod"`.
