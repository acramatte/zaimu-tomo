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

- [ ] T001 Add nullable `content_sha256` to `documents`, nullable `source_document_sha256` and `source_file_reuse_confirmed boolean NOT NULL DEFAULT false` to `journal_entries`, plus the partial unique index on `journal_entries (user_id, source_document_sha256)` where the digest is not null and reuse is not confirmed, in one SQL-only Ecto migration.
- [ ] T002 Add the fields and changeset handling (including the index's `unique_constraint`) to `lib/zaimu_tomo/documents/document.ex` and `lib/zaimu_tomo/accounting/journal_entry.ex`.
- [ ] T003 [P] Add a shared raw-byte SHA-256 helper and unit tests for stable encoding and changed-byte behavior.
- [ ] T004 Update document/journal fixtures so existing rows can omit fingerprints and targeted tests can provide explicit values.

## Phase 2 — Capture upload fingerprints

- [ ] T005 Add a `Documents` store-and-hash function (for example, `store_upload/2`) that reads the upload, hashes the exact binary passed to `Storage.put_object/2`, and returns object key, filename, and digest together; test it in `test/zaimu_tomo/documents_test.exs`.
- [ ] T006 Use that function in `lib/zaimu_tomo_web/live/document_upload_live.ex` and `lib/zaimu_tomo_web/live/document_live/form.ex`, replacing the duplicated read-and-store step; preserve the existing digest for metadata-only edits and replace it with new bytes on file replacement.
- [ ] T007 Add `test/zaimu_tomo_web/live/document_live_test.exs` coverage for persisted hash, object/hash byte agreement, replacement, and upload compensation.

## Phase 3 — Enforce and present exact-file duplicates

- [ ] T008 Load the source document fingerprint through the scoped review/extraction/document relationship in `lib/zaimu_tomo/review.ex`.
- [ ] T009 Copy the fingerprint to the journal entry in `lib/zaimu_tomo/accounting.ex`; map its unique-constraint failure through the existing `:duplicate_invoice` transaction path.
- [ ] T010 Extend duplicate candidate lookup in `lib/zaimu_tomo/accounting.ex` to include exact fingerprint matching, preserve user scoping and field matching, and return a clear match reason that distinguishes a confirmable file-only match from a hard block.
- [ ] T011 Add explicit reuse confirmation to approval and amendment in `lib/zaimu_tomo/review.ex`: set `source_file_reuse_confirmed` only for a confirmed file-only match and log the confirmation with the matched journal-entry ID in the posting transaction.
- [ ] T012 Update `lib/zaimu_tomo_web/live/review_live/show.ex` and `lib/zaimu_tomo_web/live/review_live/edit.ex` for exact-file blocking, the explicit reuse confirmation, and candidate provenance; hard-block copy directs the reviewer to reject the duplicate review.
- [ ] T013 [P] Update `lib/zaimu_tomo_web/components/zaimu_components.ex` if the candidate component needs to display the match reason.
- [ ] T014 Add context tests in `test/zaimu_tomo/accounting_test.exs` and `test/zaimu_tomo/review_test.exs` for same-user exact matches, different-user isolation, approval/amendment rollback, database enforcement, a re-extracted posted document, confirmed reuse (flag + event), and refusal to confirm a hard block.
- [ ] T015 Add `test/zaimu_tomo_web/live/review_live_test.exs` scenarios for exact-file blocking, existing entry link, reject guidance for hard blocks, reused QR-bill confirmation after amending the date, field mismatch, unchanged soft-match confirmation, and cross-user isolation.

## Phase 4 — Backfill

- [ ] T016 Implement an idempotent fingerprint-backfill task using `ZaimuTomo.Storage`; update journal entries one row at a time, report missing/unreadable objects and unique-index collisions (left null), and never log document bytes.
- [ ] T017 Add backfill tests for successful hashing, repeat execution, absent objects, storage failures, journal-entry propagation, a same-user historical collision that leaves both entries intact, and a human-confirmed reuse resolution.
- [ ] T018 Confirm no database-level immutability trigger on `journal_entries` blocks the backfill update; if one exists or is planned, sequence the backfill first or allow this single column update explicitly.
- [ ] T019 Document the online backfill → report review → rerun procedure and the behavior for missing historical objects and collisions.

## Phase 5 — Verification

- [ ] T020 Run the focused documents/accounting/review/LiveView tests listed in `plan.md`.
- [ ] T021 Run `mix precommit` and inspect the final diff for unrelated changes.
- [ ] T022 Render every Mermaid diagram and check local links; update statuses only after the corresponding implementation/backfill evidence exists.
