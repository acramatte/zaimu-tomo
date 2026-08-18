# Plan: S3-Compatible Document Storage

**Input**: User request + decisions documented in `/specs/003-s3-document-storage/spec.md`
**Prerequisites**: spec.md, research.md
**Status**: In progress — Phases 1–2 complete; Phases 3–6 remain

## Phase 0 — Pre-implementation decisions  *(complete — 2026-08-05)*

- [x] Resolve open questions from spec.md §14 — recorded decisions: image pin `rustfs/rustfs:1.0.0-beta.12` **+ digest** (spec.md §14); versioning + Object Lock at bucket creation; Content-Type mapping inside `Storage.S3`; `verify_storage` on-demand + nightly backup cron step.
- [x] Confirm the RustFS version/tag and check whether the installed version supports bucket versioning / object lock — confirmed: `1.0.0-beta.12` is the latest tag (Docker Hub, 2026-07-30); versioning + Object Lock are supported (docs.rustfs.com).

## Phase 1 — Storage foundation  *(complete — 2026-08-18)*

**Goal**: a swappable S3 storage layer with no callers yet.

1. Add `{:aws_signature, "~> 0.4"}` to `mix.exs` deps; `mix deps.get`.
2. Create `lib/zaimu_tomo/storage.ex` as the public facade and `lib/zaimu_tomo/storage/adapter.ex` as the behaviour. The facade exposes `put_object/2`, `get_object/2`, `delete_object/1`, and `head_object/1`; callbacks receive the configured storage Keyword as their final argument.
3. Create `lib/zaimu_tomo/storage/s3.ex` — Req + `:aws_signature` adapter, path-style aware (R2), `Content-Type` from extension (R3).
4. Create `lib/zaimu_tomo/storage/memory.ex` — ETS-backed in-memory implementation for tests.
5. Add `:storage` Keyword config (including `adapter`) to `config/config.exs`, env-var overrides to `config/runtime.exs` (R1: `S3_*` only), and the Memory adapter to `config/test.exs`.
6. Tests: `Req.Test` cases for `Storage.S3` (URL shape, SigV4 headers, path_style on/off); `Storage.Memory` unit tests.

**Verify**: `mix compile --warnings-as-errors`; storage tests green with no network.

## Phase 2 — Database  *(complete)*

1. Generate migration `rename_documents_filepath_to_object_key` via `mix ecto.gen.migration`.
2. `ALTER TABLE ... RENAME COLUMN filepath TO object_key` + backfill `UPDATE` (spec §5.2).
3. Update `lib/zaimu_tomo/documents/document.ex`: field + changeset cast/validate.
4. Update fixtures and tests referencing `filepath` (spec §12 list).

**Verify**: `POSTGRES_PORT=55432 mix test test/zaimu_tomo/documents_test.exs` and migration round-trip (`mix ecto.rollback` / `mix ecto.migrate`).

## Phase 3 — Flow changes

1. `document_upload_live.ex` `do_consume/1`: PUT instead of `File.cp!`; best-effort delete on DB failure.
2. `document_live/form.ex` `handle_event("save", ...)`: same consume change; on replacement, delete the old key only after the DB update succeeds and clean up the new key if the update fails.
3. `ocr_worker.ex` `process/1`: download object to temp file, feed `DocumentOCR.process/1`, and remove the temp file in an `after` block; delete `build_document_path/1`.
4. `documents.ex` `delete_document/2`: `Storage.delete_object` only after successful row delete.

**Verify**: LiveView/unit tests green against Storage.Memory. The RustFS end-to-end check belongs to Phase 4, after the service and bucket exist.

## Phase 4 — Infrastructure

1. `docker-compose.yml`: add `rustfs` service (digest-pinned `rustfs/rustfs:1.0.0-beta.12@sha256:...`, spec §7) + volumes (spec §7); create the dev bucket once with versioning + Object Lock via `mc mb --with-lock` (or the console).
2. Keep the old uploads directory and `zaimu_tomo_uploads` volume for this migration release.
3. `config/deploy.yml`: add the `rustfs` accessory and generic `S3_*` app env while retaining the old volume until Phase 5 validates migration.
4. `.kamal/secrets.example`: add `RUSTFS_SECRET_KEY` and `S3_SECRET_ACCESS_KEY` with their initial shared-value relationship documented; keep endpoint/bucket/access-key ID in clear env.
5. `DEPLOYMENT.md`: update storage + backup sections (spec §8, §9).
6. `README.md`: document the dev storage service and `S3_*` variables.
7. Add an opt-in `:integration` Testcontainers suite using the digest-pinned RustFS image, `eu-central-1`, and an isolated bucket. Validate real SigV4 authentication plus path-style PUT/GET/HEAD/DELETE byte round-trips; keep Docker-required tests outside the default suite.

**Verify**: fresh `docker compose up` boots db + RustFS readiness; create the locked dev bucket; dev app uploads and OCRs an invoice with zero env vars. On a Docker-capable machine/CI runner, `RUN_INTEGRATION=true mix test --only integration` passes; ordinary `mix test` and `mix precommit` remain Docker-free.

## Phase 5 — Migration tooling

1. `mix zaimu_tomo.migrate_to_s3 --source-dir PATH` — idempotent backfill of existing local files, HEAD-before-PUT, non-zero on missing source/failed upload (spec §10).
2. `mix zaimu_tomo.verify_storage` — HEAD every `documents.object_key`, report missing (R4).
3. Validate the RustFS backup method. Back up/export objects first, then `pg_dump`, then `verify_storage`; do not assume a live `restic /data` walk is safe without validation (spec §9).
4. Rollout (prod): drain workers and pause new uploads; with the old `zaimu_tomo_uploads` volume still mounted, run `mix zaimu_tomo.migrate_to_s3 --source-dir PATH`, confirm `verify_storage` reports 0 missing, perform a restore check, then publish a cleanup deployment that drops the volume and Dockerfile upload directory (spec §10).

**Verify**: run `migrate_to_s3 --source-dir` on a copy of `priv/uploads`; rerun it to prove idempotency; `verify_storage` reports 0 missing; restore drill on a scratch VM; production rollout per step 4.

## Phase 6 — Full suite

- [ ] `POSTGRES_PORT=55432 mix precommit`

## Later (separate PR): RustFS → Hetzner Object Storage

Not a plan phase — an optional future workstream, started only after Phase 6 (see spec.md §11). Copy with rclone, config swap (`S3_ENDPOINT`, `S3_PATH_STYLE=false`), `verify_storage`, decommission accessory.
