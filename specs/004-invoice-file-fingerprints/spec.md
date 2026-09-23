# Feature Specification: Exact-Byte Invoice File Fingerprints

**Feature Branch**: `docs/invoice-file-fingerprinting` (specification branch; implementation branch to follow)
**Created**: 2026-09-23
**Status**: Proposed — documentation only; no runtime code is included
**Depends on**: PR #60, `feat/duplicate-invoice-detection`

## 1. Context and problem

PR #60 detects duplicate invoices using reviewer-confirmed invoice fields. `Accounting.duplicate_candidates/2` finds a strong match by user, issuer, and invoice number, or a soft match by issuer, date, amount, and currency. Posting of a numbered duplicate is protected by a database uniqueness constraint.

Those semantic matches depend on extracted values. A second OCR/LLM run may miss or vary a field even when the user uploads the exact same document bytes. A raw-file fingerprint adds deterministic evidence that is independent of OCR and LLM output.

## 2. Goals and non-goals

### Goals

- **G1**: Compute a SHA-256 digest over the exact bytes accepted by the upload flow.
- **G2**: Preserve that digest on the document record and carry it into a journal entry when an invoice is posted.
- **G3**: Treat an exact same-user file match as a strong duplicate, show the existing journal entry, and prevent a second posting.
- **G4**: Preserve PR #60's invoice-number matching and soft field-tuple warnings unchanged in meaning.
- **G5**: Make the database enforce the posting invariant atomically and include existing stored documents through an explicit backfill.

### Non-goals

- Hashing OCR Markdown, LLM responses, or extracted fields as a duplicate mechanism.
- Perceptual/image similarity, OCR normalization, embeddings, or fuzzy matching.
- Cross-user matching or exposing fingerprints in the UI, logs, or external AI requests.
- Preventing a duplicate upload from being stored or reviewed. The posting is the enforcement boundary.
- Changing the OCR/LLM pipeline or adding an external dependency.

## 3. Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Hash the raw uploaded bytes with SHA-256 and encode as 64 lowercase hexadecimal characters. | The digest represents the object itself and is unaffected by nondeterministic OCR/LLM output. |
| D2 | Store `documents.content_sha256` as the current object's fingerprint. Keep it nullable for legacy rows and non-upload fixtures until backfill is complete. | Documents own the uploaded bytes; SQL migrations must not make object-store requests. |
| D3 | Copy the source digest to `journal_entries.source_document_sha256` at posting. | A unique constraint cannot span the document → extraction → review → journal joins. The copied immutable value lets PostgreSQL enforce the posting rule in the same transaction. |
| D4 | Enforce uniqueness on `(user_id, source_document_sha256)` only for non-null digests. Do not make `documents.content_sha256` unique. | Multiple document/review records remain available; only a second posted journal entry is blocked. Per-user scope avoids cross-user information leakage. |
| D5 | An exact-file match is a strong, blocking match. Keep invoice number as the other strong match and the exact field tuple as a soft warning. | Same bytes are a strong duplicate signal; the existing soft-match confirmation semantics remain intact. |
| D6 | Backfill through the configured `Storage` boundary, then create the unique index after collision preflight. | Existing postings need fingerprints for historical coverage; storage I/O does not belong in an Ecto migration. |

## 4. Functional requirements

- **FR-001**: Both upload entry points MUST hash the exact binary passed to `Storage.put_object/2` and persist that digest with the document row.
- **FR-002**: Replacing a document's stored bytes MUST update its `content_sha256` with the object key. Editing metadata without replacing bytes MUST preserve the digest.
- **FR-003**: Posting and amending an invoice MUST carry the source document digest into the journal entry created by the approval transaction.
- **FR-004**: Candidate lookup MUST match a non-null source digest only within the same user's journal entries, in addition to existing field-based criteria.
- **FR-005**: A same-user duplicate digest MUST fail the journal-entry insert through a database uniqueness constraint. The surrounding review transaction MUST roll back, leave the review pending, and write neither a journal entry nor its dependent tax claim/event.
- **FR-006**: The review UI MUST identify an exact-file match, link to the existing entry, and prevent approval/amendment. A semantic soft match MUST remain a warning that can be confirmed.
- **FR-007**: A historical backfill MUST be repeatable, report missing/unreadable objects, and never delete or merge journal entries automatically.
- **FR-008**: Missing/null hashes MUST not match. If any existing object's bytes cannot be read, historical coverage MUST be reported as incomplete rather than implied to be complete.

## 5. Acceptance scenarios

1. **Same bytes, extraction differs**: Given a previously posted invoice and a second document with identical bytes but different extracted issuer/number/amount, when the second invoice is reviewed, then the previous journal entry is shown as an exact-file duplicate and posting is blocked.
2. **Same bytes, other user**: Given another user's posted invoice with the same bytes, when the current user's document is reviewed, then no candidate is returned and posting is not blocked by that other user's digest.
3. **Different bytes, same invoice facts**: Given different source bytes with matching invoice number and issuer, then PR #60's strong semantic match still blocks a second posting.
4. **Different bytes, same soft tuple**: Given no invoice number but the same issuer/date/amount/currency, then the existing possible-duplicate warning and explicit confirmation flow remain available.
5. **Concurrent identical postings**: Given two same-user pending reviews with the same digest, when both are posted concurrently, then at most one journal entry is committed by the database constraint.
6. **File replacement**: Given a document whose uploaded object is replaced, then the current document hash reflects the new bytes; any already-created journal entry retains the digest snapshot captured when it was posted.
7. **Legacy object missing**: Given a historical document whose object cannot be read, then backfill reports it and leaves its hash null; no fake or OCR-derived hash is stored.

## 6. Data and privacy

- Proposed fields: `documents.content_sha256` and `journal_entries.source_document_sha256`, nullable during rollout.
- Proposed index: unique `(user_id, source_document_sha256)` on `journal_entries` where the digest is not null.
- The digest is computed from bytes before OCR. It is not an OCR result and must not be sent to Langfuse, the LLM, or the browser.
- The document fingerprint and candidate lookup remain user-scoped. Do not use global digest lookups as an existence oracle.
- SHA-256 equality identifies byte-identical uploads, not visually or semantically similar documents. Re-rendered PDFs and re-scans remain the responsibility of semantic matching.

## 7. Rollout and recovery

1. Add nullable columns and deploy code that records new upload hashes and copies them to new journal entries.
2. Pause document uploads and invoice approvals for the historical backfill/index cutover, or use an equivalent guarded rollout that prevents posting races.
3. Run the idempotent backfill, inspect unreadable/missing objects, and preflight same-user duplicate journal fingerprints.
4. If historical collisions exist, stop for human ledger review; do not delete or merge entries automatically.
5. Create the partial unique index, verify it exists, and resume writes. If bytes are missing, document the resulting partial historical coverage.

The backfill task must use the private storage facade and clean up any temporary file it creates. SQL migrations must remain database-only.

## 8. Implementation documentation

- Ordered implementation and deployment plan: [plan.md](plan.md)
- Task checklist: [tasks.md](tasks.md)
- C4 model: [c4-model.md](c4-model.md)
- Existing duplicate-detection design: PR [#60](https://github.com/acramatte/zaimu-tomo/pull/60)
