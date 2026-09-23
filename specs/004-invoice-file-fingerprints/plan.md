# Plan: Exact-Byte Invoice File Fingerprints

**Input**: User request and decisions in [spec.md](spec.md)
**Prerequisites**: PR #60 (`feat/duplicate-invoice-detection`)
**Status**: Proposed — implementation and runtime tests have not been run

## Phase 0 — Confirm contract

1. Keep the fingerprint strictly byte-based: SHA-256 of the exact uploaded binary, lowercase 64-character hex.
2. Decide the posted-invoice invariant: identical bytes for the same user must not produce a second journal entry.
3. Keep existing semantic behavior: invoice number is strong; issuer/date/amount/currency is a soft warning.
4. Confirm operations can pause uploads/approvals while existing object hashes are backfilled and the unique index is created.

**Gate**: acceptance scenarios in `spec.md` are agreed; no OCR/LLM or perceptual fingerprint scope is added.

## Phase 1 — Add additive persistence

1. Add nullable `documents.content_sha256` and `journal_entries.source_document_sha256` columns.
2. Add schema fields and changeset support in `lib/zaimu_tomo/documents/document.ex` and `lib/zaimu_tomo/accounting/journal_entry.ex`.
3. Add a shared digest helper using `:crypto.hash(:sha256, bytes)` and lowercase hex encoding; do not add a dependency.
4. Add tests for digest format and exact-byte behavior, including that a one-byte change changes the digest.

**Gate**: additive migration applies and rolls back; old fixture rows remain valid with null fingerprints.

## Phase 2 — Capture uploaded bytes

1. Update `lib/zaimu_tomo_web/live/document_upload_live.ex` to compute a digest from the same `body` passed to `Storage.put_object/2`, then persist it with `Documents.create_document/2`.
2. Update `lib/zaimu_tomo_web/live/document_live/form.ex` similarly. For `:edit`, update the digest only when a new object is uploaded; preserve it for metadata-only edits.
3. Preserve the existing storage compensation order: clean up a newly uploaded object if row persistence fails; remove an old object only after a successful replacement.
4. Keep the hash on the document row, not in filenames, object keys, OCR output, or LLM prompts.

**Gate**: upload tests prove the stored digest corresponds to the bytes in the Memory adapter; replacement and failed persistence preserve cleanup semantics.

## Phase 3 — Enforce at journal posting

1. Make the source document available via the existing `ReviewDecision → ExtractedContent → Document` relationship. Scope every lookup to the owning user.
2. Pass the document digest into `Accounting.create_multi_from_decision/2` and write it to `JournalEntry.source_document_sha256` as part of the existing posting transaction.
3. Extend duplicate-constraint error mapping in `Accounting.duplicate_error?/1` to include the source-file fingerprint constraint. Preserve rollback behavior in `Review.post_review_transaction/5` for both approval and amendment.
4. Extend duplicate candidates to include exact source-hash matches and retain the current field-based match. Return match provenance (or equivalent) so a candidate matching both paths is shown once with the strongest reason.
5. Update callers in `ReviewLive.Show` and `ReviewLive.Edit`. Exact-file candidates are strong/blocking; soft field-tuple matches keep their current warning/confirmation behavior. Update UI copy so a hash match is not described as an invoice-number match.

**Gate**: context tests prove a hash duplicate rolls back review, journal entry, tax claim, and event log; same-user uniqueness holds at the database boundary.

## Phase 4 — Backfill and activate the unique index

1. Add an idempotent task (for example, `mix zaimu_tomo.backfill_document_fingerprints`) that enumerates documents with null hashes, reads bytes through `ZaimuTomo.Storage`, and updates hashes without logging the bytes.
2. Populate `journal_entries.source_document_sha256` from each journal entry's review decision, extracted content, and document.
3. Report totals for processed, already complete, missing objects, read failures, and hash collisions. Do not mutate/delete ledger entries to resolve collisions.
4. Pause uploads and approvals for the cutover. Run the task, review failures/collisions, then add the partial unique index in a separate SQL-only migration. Resume writes only after index verification.
5. If any source object is missing, leave its fingerprint null and report incomplete legacy coverage. Do not claim historical exact-file protection for those rows.

**Gate**: rerunning the backfill is safe; the unique-index migration succeeds only after collisions are resolved; a direct duplicate insert is rejected by PostgreSQL.

## Phase 5 — Verify and reconcile documentation

1. Run focused tests for documents, accounting, review, document upload LiveViews, review LiveViews, and the backfill task.
2. Run `mix precommit`; inspect `git status` afterward and keep the diff limited to this feature.
3. Verify the C4 diagrams render, links resolve, and the spec/plan/task status describes a proposal until runtime work is completed.
4. Record the actual backfill and index cutover procedure in deployment documentation when implementation is scheduled.

**Implementation test command** (future gate):

```sh
mix test test/zaimu_tomo/documents_test.exs test/zaimu_tomo/accounting_test.exs test/zaimu_tomo/review_test.exs test/zaimu_tomo_web/live/document_live_test.exs test/zaimu_tomo_web/live/review_live_test.exs
```

Then run `mix precommit`. These commands are planned; they were not run for this documentation-only change.

## Change surface and dependencies

- Upload boundary: `document_upload_live.ex` and `document_live/form.ex` both consume uploads and store objects.
- Persistence boundary: `Document` stores the current file fingerprint; `JournalEntry` stores the posting-time source fingerprint.
- Posting boundary: `Review.post_review_transaction/5` composes journal creation into the review transaction; PostgreSQL uniqueness is the race-safe enforcement point.
- Candidate/UI seam: `Accounting.duplicate_candidates/2` is consumed from both review show and edit flows. Both must receive the pending document fingerprint and render the match reason consistently.
- OCR worker and LLM extraction require no changes.

The storage/backfill operation is intentionally separate from schema migration code. See [c4-model.md](c4-model.md) for the data flow and component boundaries.
