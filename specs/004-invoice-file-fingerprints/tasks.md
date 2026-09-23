# Tasks: Exact-Byte Invoice File Fingerprints

**Input**: Design documents from this directory
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md)
**Status**: Planned — no implementation tasks are complete
**Tests**: Financial data integrity requires context, database-constraint, upload, and LiveView coverage

## Format

`[ ] TNNN [P?] [Phase] Description`

- `[P]` means the task can run in parallel without editing the same boundary.
- Phases follow `plan.md`; no task is complete merely because the design is documented.

## Phase 1 — Add persistence

- [ ] T001 Add nullable `content_sha256` to `documents` and `source_document_sha256` to `journal_entries` in a SQL-only Ecto migration.
- [ ] T002 Add the fields and changeset handling to `lib/zaimu_tomo/documents/document.ex` and `lib/zaimu_tomo/accounting/journal_entry.ex`.
- [ ] T003 [P] Add a shared raw-byte SHA-256 helper and unit tests for stable encoding and changed-byte behavior.
- [ ] T004 Update document/journal fixtures so existing rows can omit fingerprints and targeted tests can provide explicit values.

## Phase 2 — Capture upload fingerprints

- [ ] T005 Compute the digest from the same binary stored by `Storage.put_object/2` in `lib/zaimu_tomo_web/live/document_upload_live.ex`.
- [ ] T006 Compute and persist the digest in `lib/zaimu_tomo_web/live/document_live/form.ex`; preserve the existing digest for metadata-only edits and replace it with new bytes on file replacement.
- [ ] T007 Add `test/zaimu_tomo_web/live/document_live_test.exs` coverage for persisted hash, object/hash byte agreement, replacement, and upload compensation.

## Phase 3 — Enforce and present exact-file duplicates

- [ ] T008 Load the source document fingerprint through the scoped review/extraction/document relationship in `lib/zaimu_tomo/review.ex`.
- [ ] T009 Copy the fingerprint to the journal entry in `lib/zaimu_tomo/accounting.ex`; map its unique-constraint failure through the existing `:duplicate_invoice` transaction path.
- [ ] T010 Extend duplicate candidate lookup in `lib/zaimu_tomo/accounting.ex` to include exact fingerprint matching, preserve user scoping and field matching, and return a clear match reason.
- [ ] T011 Update `lib/zaimu_tomo_web/live/review_live/show.ex` and `lib/zaimu_tomo_web/live/review_live/edit.ex` for exact-file blocking and candidate provenance.
- [ ] T012 [P] Update `lib/zaimu_tomo_web/components/zaimu_components.ex` if the candidate component needs to display the match reason.
- [ ] T013 Add context tests in `test/zaimu_tomo/accounting_test.exs` and `test/zaimu_tomo/review_test.exs` for same-user exact matches, different-user isolation, approval/amendment rollback, and database enforcement.
- [ ] T014 Add `test/zaimu_tomo_web/live/review_live_test.exs` scenarios for exact-file blocking, existing entry link, field mismatch, unchanged soft-match confirmation, and cross-user isolation.

## Phase 4 — Backfill and index cutover

- [ ] T015 Implement an idempotent fingerprint-backfill task using `ZaimuTomo.Storage`; report missing/unreadable objects and never log document bytes.
- [ ] T016 Add backfill tests for successful hashing, repeat execution, absent objects, storage failures, and journal-entry propagation.
- [ ] T017 Add a preflight report for duplicate non-null `{user_id, source_document_sha256}` journal entries; require human resolution without deleting or merging ledger rows.
- [ ] T018 Add the partial unique index on `(user_id, source_document_sha256)` after backfill; verify the constraint rejects a second same-user posting and permits null/history-unavailable rows.
- [ ] T019 Document the pause → backfill → collision review → index → resume procedure and the behavior for missing historical objects.

## Phase 5 — Verification

- [ ] T020 Run the focused documents/accounting/review/LiveView tests listed in `plan.md`.
- [ ] T021 Run `mix precommit` and inspect the final diff for unrelated changes.
- [ ] T022 Render every Mermaid diagram and check local links; update statuses only after the corresponding implementation/cutover evidence exists.
