# Plan: Exact-Byte Invoice File Fingerprints

**Input**: User request and decisions in [spec.md](spec.md)
**Prerequisites**: PR #60 (`feat/duplicate-invoice-detection`)
**Status**: Proposed — implementation and runtime tests have not been run

## Phase 0 — Confirm contract

1. Keep the fingerprint strictly byte-based: SHA-256 of the exact uploaded binary, lowercase 64-character hex.
2. Decide the posted-invoice invariant: identical bytes for the same user must not produce a second journal entry without an explicit reuse confirmation.
3. Keep existing semantic behavior: invoice number is strong; issuer/date/amount/currency is a soft warning.
4. Confirm the reuse rule (spec D10): an exact-file match is confirmable per posting only when neither semantic rule also matches.
5. Confirm the backfill can run online: the unique index exists before it starts, so no upload/approval pause is required.

**Gate**: acceptance scenarios in `spec.md` are agreed; no OCR/LLM or perceptual fingerprint scope is added.

## Phase 1 — Add additive persistence

1. Add nullable `documents.content_sha256` and `journal_entries.source_document_sha256` columns, `journal_entries.source_file_reuse_confirmed boolean NOT NULL DEFAULT false`, and the partial unique index on `journal_entries (user_id, source_document_sha256) WHERE source_document_sha256 IS NOT NULL AND NOT source_file_reuse_confirmed`, in one SQL-only migration. Every existing digest is null, so the index cannot collide.
2. Add schema fields and changeset support in `lib/zaimu_tomo/documents/document.ex` and `lib/zaimu_tomo/accounting/journal_entry.ex`, including a `unique_constraint` for the new index.
3. Add a shared digest helper using `:crypto.hash(:sha256, bytes)` and lowercase hex encoding; do not add a dependency.
4. Add tests for digest format and exact-byte behavior, including that a one-byte change changes the digest.

**Gate**: additive migration applies and rolls back; old fixture rows remain valid with null fingerprints; a direct second same-user insert with the same non-null digest is rejected by PostgreSQL unless it is marked as a confirmed reuse.

## Phase 2 — Capture uploaded bytes

1. Add one `Documents` function (for example, `Documents.store_upload/2` taking the temporary upload path and client filename) that reads the bytes, computes the digest, calls `Storage.put_object/2` with that same binary, and returns `object_key`, `filename`, and `content_sha256` together.
2. Replace the duplicated read-and-store step in `lib/zaimu_tomo_web/live/document_upload_live.ex` and `lib/zaimu_tomo_web/live/document_live/form.ex` with that function and pass the returned attributes to `Documents.create_document/2` / `update_document/3`. For `:edit`, the digest changes only when a new object is uploaded; metadata-only edits preserve it.
3. Preserve the existing storage compensation order in the LiveViews: clean up a newly uploaded object if row persistence fails; remove an old object only after a successful replacement.
4. Keep the hash on the document row, not in filenames, object keys, OCR output, or LLM prompts.

**Gate**: upload tests prove the stored digest corresponds to the bytes in the Memory adapter; replacement and failed persistence preserve cleanup semantics.

## Phase 3 — Enforce at journal posting

1. Make the source document available via the existing `ReviewDecision → ExtractedContent → Document` relationship. Scope every lookup to the owning user.
2. Pass the document digest into `Accounting.create_multi_from_decision/2` and write it to `JournalEntry.source_document_sha256` as part of the existing posting transaction.
3. Extend duplicate-constraint error mapping in `Accounting.duplicate_error?/1` to include the source-file fingerprint constraint. Preserve rollback behavior in `Review.post_review_transaction/5` for both approval and amendment.
4. Extend duplicate candidates to include exact source-hash matches and retain the current field-based match. Return match provenance (or equivalent) so a candidate matching both paths is shown once with the strongest reason, and so callers can tell a confirmable file-only match from a hard block (file match plus invoice-number or soft-tuple match).
5. Add an explicit reuse-confirmation input to approval and amendment. `Review.post_review_transaction/5` writes `source_file_reuse_confirmed = true` only when the reviewer confirmed a confirmable file match, and records the confirmation plus matched journal-entry ID in the event log in the same transaction. Amendments re-run the candidate check on the amended facts, so a corrected date can turn a hard block into a confirmable match.
6. Update callers in `ReviewLive.Show` and `ReviewLive.Edit`. A hard-blocked exact-file match directs the reviewer to reject; a confirmable file-only match asks “Is this a reused bill for a new period?” and posts only after explicit confirmation; soft field-tuple matches keep their current warning/confirmation behavior. Update UI copy so a hash match is not described as an invoice-number match.

**Gate**: context tests prove an unconfirmed hash duplicate rolls back review, journal entry, tax claim, and event log; a confirmed reuse posts with the flag and event; a hard block cannot be confirmed; same-user uniqueness holds at the database boundary (index from Phase 1).

## Phase 4 — Backfill existing fingerprints

1. Add an idempotent task (for example, `mix zaimu_tomo.backfill_document_fingerprints`) that enumerates documents with null hashes, reads bytes through `ZaimuTomo.Storage`, and updates hashes without logging the bytes.
2. Populate `journal_entries.source_document_sha256` from each journal entry's review decision, extracted content, and document, one entry per update so a unique violation affects only that row. This is the only permitted update of an existing entry's fingerprint (spec D7); it must run before any database-level immutability trigger on `journal_entries`, or that trigger must explicitly allow it.
3. Report totals for processed, already complete, missing objects, read failures, and hash collisions (rows rejected by the unique index, left null). Do not mutate/delete ledger entries to resolve collisions automatically; a human may explicitly mark a reported later entry as a confirmed reuse, which the task applies in one update with its digest.
4. Run online; no upload/approval pause is needed because the index already guards concurrent postings.
5. If any source object is missing, leave its fingerprint null and report incomplete legacy coverage. Do not claim historical exact-file protection for those rows.

**Gate**: rerunning the backfill is safe; a historical collision is reported and leaves both entries intact; concurrent postings during the backfill cannot create a same-user duplicate.

## Phase 5 — Verify and reconcile documentation

1. Run focused tests for documents, accounting, review, document upload LiveViews, review LiveViews, and the backfill task.
2. Run `mix precommit`; inspect `git status` afterward and keep the diff limited to this feature.
3. Verify the C4 diagrams render, links resolve, and the spec/plan/task status describes a proposal until runtime work is completed.
4. Record the actual backfill procedure and its collision report handling in deployment documentation when implementation is scheduled.

**Implementation test command** (future gate):

```sh
mix test test/zaimu_tomo/documents_test.exs test/zaimu_tomo/accounting_test.exs test/zaimu_tomo/review_test.exs test/zaimu_tomo_web/live/document_live_test.exs test/zaimu_tomo_web/live/review_live_test.exs
```

Then run `mix precommit`. These commands are planned; they were not run for this documentation-only change.

## Change surface and dependencies

- Upload boundary: `document_upload_live.ex` and `document_live/form.ex` both consume uploads; they share one `Documents` store-and-hash function so the key and digest cannot diverge.
- Persistence boundary: `Document` stores the current file fingerprint; `JournalEntry` stores the posting-time source fingerprint.
- Posting boundary: `Review.post_review_transaction/5` composes journal creation into the review transaction; PostgreSQL uniqueness is the race-safe enforcement point.
- Candidate/UI seam: `Accounting.duplicate_candidates/2` is consumed from both review show and edit flows. Both must receive the pending document fingerprint and render the match reason consistently.
- OCR worker and LLM extraction require no changes.

The storage/backfill operation is intentionally separate from schema migration code. See [c4-model.md](c4-model.md) for the data flow and component boundaries.
