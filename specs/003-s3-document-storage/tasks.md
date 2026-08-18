# Tasks: S3-Compatible Document Storage

**Input**: Design documents from `/specs/003-s3-document-storage/`
**Prerequisites**: plan.md, spec.md, research.md
**Tests**: Tests are included; this is a financial system requiring high data integrity
**Organization**: Tasks are grouped by phase (matching plan.md). No user stories — infrastructure feature.

## Format: `[ID] [P?] [Phase] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Phase]**: Which plan phase this task belongs to (P1–P6)
- Include exact file paths in descriptions

## Path Conventions

- **Phoenix Web App**: `lib/zaimu_tomo_web/`, `test/zaimu_tomo_web/`
- **Elixir/Ecto**: Standard Phoenix project structure

---

## Phase 1: Storage Foundation

- [x] T001 Add `{:aws_signature, "~> 0.4"}` to deps in `mix.exs`
- [x] T002 [P] Create the `ZaimuTomo.Storage` facade in `lib/zaimu_tomo/storage.ex` and `ZaimuTomo.Storage.Adapter` behaviour in `lib/zaimu_tomo/storage/adapter.ex`
- [x] T003 [P] Create `ZaimuTomo.Storage.S3` in `lib/zaimu_tomo/storage/s3.ex` (Req + `:aws_signature`, path-style flag, Content-Type from extension)
- [x] T004 [P] Create `ZaimuTomo.Storage.Memory` in `lib/zaimu_tomo/storage/memory.ex` (ETS-backed)
- [x] T005 Add `:storage` config default to `config/config.exs`
- [x] T006 Add `S3_*` env overrides to `config/runtime.exs` and set the Memory adapter in `config/test.exs`
- [x] T007 [P] Test `Storage.S3` with `Req.Test` (URL shape, SigV4 headers, path_style on/off) in `test/zaimu_tomo/storage/s3_test.exs`
- [x] T008 [P] Test `Storage.Memory` in `test/zaimu_tomo/storage/memory_test.exs`

## Phase 2: Database

- [ ] T009 Generate migration via `mix ecto.gen.migration rename_documents_filepath_to_object_key`
- [ ] T010 Migration: rename `filepath` → `object_key` + backfill `UPDATE` (spec.md §5.2)
- [ ] T011 Update schema + changeset in `lib/zaimu_tomo/documents/document.ex`
- [ ] T012 [P] Update fixture in `test/support/fixtures/documents_fixtures.ex` (`filepath` → `object_key`)
- [ ] T013 [P] Update tests referencing `filepath`: `test/zaimu_tomo/documents_test.exs`, `test/zaimu_tomo/accounting_test.exs`, `test/zaimu_tomo/document_processing_test.exs`, `test/zaimu_tomo/document_processing/worker_test.exs`, `test/zaimu_tomo_web/controllers/page_controller_test.exs`, `test/zaimu_tomo_web/live/journal_entry_live_test.exs`

## Phase 3: Flow Changes

- [ ] T014 Replace `File.cp!` with `Storage.put_object` in `lib/zaimu_tomo_web/live/document_upload_live.ex` (`do_consume/1`), add best-effort delete on DB failure
- [ ] T015 Replace `File.cp!` with `Storage.put_object` in `lib/zaimu_tomo_web/live/document_live/form.ex` (`handle_event("save", ...)`); clean up the new key on failed update and the prior key only after successful replacement
- [ ] T016 Download to temp file in `lib/zaimu_tomo/document_processing/ocr_worker.ex` (`process/1`); remove it in an `after` block; remove `build_document_path/1`
- [ ] T017 Add object deletion after successful row delete in `lib/zaimu_tomo/documents.ex` (`delete_document/2`)
- [ ] T018 Add focused regression tests for storage failure cleanup, temp-file cleanup, and delete-after-row semantics

## Phase 4: Infrastructure

- [ ] T019 [P] Add digest-pinned `rustfs` service (`rustfs/rustfs:1.0.0-beta.12@sha256:...` — full digest in spec.md §7/§14) + volumes to `docker-compose.yml`; create dev bucket with versioning/Object Lock via `mc mb --with-lock` (spec.md §7)
- [ ] T020 [P] Retain the uploads mkdir/chown through the migration release; add its removal to the Phase 5 cleanup release only
- [ ] T021 Retain `zaimu_tomo_uploads` through migration; add a rustfs accessory (same digest-pinned image as compose) + generic `S3_*` env to `config/deploy.yml`
- [ ] T022 Add `RUSTFS_SECRET_KEY` and `S3_SECRET_ACCESS_KEY` to `.kamal/secrets.example`, documenting their initial shared value; keep endpoint/bucket/access-key ID in clear env
- [ ] T023 Update `DEPLOYMENT.md` (storage + backup sections)
- [ ] T024 Update `README.md` (dev storage service, `S3_*` variables)

## Phase 5: Migration Tooling

- [ ] T025 Create `mix zaimu_tomo.migrate_to_s3 --source-dir PATH` task (HEAD-before-PUT, idempotent, non-zero summary for missing/failed sources, spec.md §10)
- [ ] T026 Create `mix zaimu_tomo.verify_storage` task (HEAD all object keys, R4)
- [ ] T027 Validate and document a RustFS-safe object backup/export method; objects first, then `pg_dump`, then `verify_storage` (spec.md §9)
- [ ] T028 Rollout: drain workers/pause uploads; run `mix zaimu_tomo.migrate_to_s3 --source-dir PATH` against production data (old volume still mounted); rerun it; `verify_storage` reports 0 missing; restore check passes; then publish cleanup deployment removing `zaimu_tomo_uploads` and Dockerfile upload directory (spec.md §10)

## Phase 6: Verification

- [ ] T029 Full suite: `POSTGRES_PORT=55432 mix precommit`
