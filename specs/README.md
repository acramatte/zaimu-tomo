# Feature specs (historical)

These folders are design records written with
[spec-kit](https://github.com/github/spec-kit) *before* each feature was built.
They capture the problem, options considered, and the plan at that time.

**They are not maintained after the feature ships**, and parts are out of date.
For example, OCR originally ran as a fire-and-forget `Task`, which Oban replaced
in September 2026. The deployment notes they mention moved from `DEPLOYMENT.md`
to [`docs/deployment.md`](../docs/deployment.md) and
[`docs/operations.md`](../docs/operations.md).

For the current system, read [`docs/`](../docs/README.md), starting with
[`docs/architecture.md`](../docs/architecture.md).

| Spec | Topic | Outcome |
|---|---|---|
| `1-data-persistence` | First draft of persisting OCR/LLM output | Earlier draft, continued in `001` |
| `001-persist-ocr-data` | `extracted_content` table, one row per processing attempt | Shipped (2026-03) |
| `002-review-ocr-data` | Human review workflow, review decisions, event log | Shipped (2026-05) |
| `003-s3-document-storage` | Moving document bytes to S3-compatible RustFS, migration and backup | Shipped (2026-08); legacy volume cleanup pending |
| `004-invoice-file-fingerprints` | Exact-byte SHA-256 fingerprints as a stronger duplicate-invoice signal than extracted fields | Shipped (2026-10); production backfill pending |
| `005-document-matters` | Persisted OCR evidence, document matters and relationships, and cited document briefs | Proposed (2026-10) |

New features may still start with a spec here. When they ship, record the
lasting decisions in `docs/architecture.md` §9 and update the affected `docs/`
pages.
