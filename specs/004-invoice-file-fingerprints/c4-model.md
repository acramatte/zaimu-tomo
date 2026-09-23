# C4 Model — Exact-Byte Invoice File Fingerprints

## Scope and status

This proposed feature adds exact-byte invoice identity to the existing duplicate-invoice review flow. It does not change the OCR/LLM pipeline and does not implement perceptual or OCR-text similarity.

**Status:** design only. The runtime fingerprint fields, backfill task, unique index, and UI behavior described below are proposed, not implemented.

## C1 — System context

```mermaid
flowchart LR
    user["Person: authenticated ZaimuTomo user"]
    app["Software system: ZaimuTomo\nPhoenix personal-finance application"]
    postgres[("Database: PostgreSQL\ndocuments, extraction/review state, journal entries")]
    objects["Private object storage\nS3-compatible RustFS / future provider"]
    mistral["Third-party system: Mistral\nOCR API"]

    user -->|uploads and reviews invoice| app
    app -->|stores document metadata and SHA-256| postgres
    app -->|stores and reads original bytes| objects
    app -->|sends file for OCR| mistral
    app -->|posts review with source fingerprint| postgres
    postgres -->|user-scoped duplicate candidates| app

    classDef thirdParty fill:#fdf4ff,stroke:#a21caf,stroke-width:2px,color:#701a75
    classDef hosted fill:#ecfdf5,stroke:#059669,stroke-width:2px,color:#064e3b
    class mistral thirdParty
    class objects hosted
```

PostgreSQL remains authoritative for document metadata, review state, journal entries, and duplicate constraints. The object store remains authoritative for the original bytes. The SHA-256 value is derived metadata—not a replacement for the stored object or invoice fields.

## C2 — Container model

```mermaid
flowchart TB
    subgraph client[User device]
      browser["Browser\nPhoenix LiveView client"]
    end

    subgraph apphost[ZaimuTomo Phoenix release / BEAM VM]
      uploads["DocumentUploadLive + DocumentLive.Form\nconsume and replace uploads"]
      fingerprint["Raw-byte SHA-256 helper\nexact bytes, lowercase hex"]
      documents["Documents context + Document schema\nscoped metadata and content_sha256"]
      storage["Storage facade + configured adapter\nprivate object operations"]
      worker["OCR worker + DocumentOCR\nOCR and extraction orchestration"]
      review["Review context + Review LiveViews\napprove/amend and show candidates"]
      accounting["Accounting context\nfield and file duplicate candidates"]
    end

    db[("PostgreSQL\ndocuments + journal_entries")]
    store["Private S3-compatible object store"]
    mistral["Mistral OCR API"]

    browser -->|upload protocol| uploads
    uploads -->|same raw body| fingerprint
    uploads -->|same raw body| storage
    fingerprint -->|content_sha256| documents
    documents --> db
    storage --> store
    worker -->|read original object| storage
    worker --> mistral
    worker -->|extraction and review state| db
    browser -->|review actions| review
    review --> accounting
    accounting -->|scoped candidate query / transactional insert| db
    db -.->|exact hash + existing semantic candidates| review
```

## C3 — Component responsibilities and proposed data flow

```mermaid
sequenceDiagram
    participant User as User
    participant Upload as Phoenix upload LiveView
    participant Hash as SHA-256 helper
    participant Storage as Storage facade
    participant Docs as Documents context
    participant DB as PostgreSQL
    participant Worker as OCR worker
    participant Review as Review context
    participant Accounting as Accounting context

    User->>Upload: upload invoice bytes
    Upload->>Hash: sha256(exact body)
    Upload->>Storage: put_object(key, exact body)
    Storage-->>Upload: stored key
    Upload->>Docs: create/update document with key and digest
    Docs->>DB: persist documents.content_sha256
    Worker->>Storage: read document object for OCR
    Worker->>DB: persist extraction and pending review
    User->>Review: approve or amend invoice
    Review->>Accounting: create journal entry inside review transaction
    Accounting->>DB: insert source_document_sha256 + invoice facts
    DB-->>Accounting: unique hash/field constraint result
    Accounting-->>Review: committed or duplicate error
    Review-->>User: post success or show linked duplicate candidate
```

### Ownership rules

| Component | Owns | Boundary |
|---|---|---|
| Upload LiveViews | Consume the incoming bytes and coordinate storage plus row persistence. | Hash exactly the body passed to storage; do not accept a client-supplied digest. |
| SHA-256 helper | Deterministic byte-to-digest conversion. | No OCR, storage, database, user, or AI dependencies. |
| `Documents` / `Document` | Current object key and its `content_sha256`. | Update key and digest together when uploaded bytes are replaced. |
| `Review` | Approval/amendment transaction and ownership scope. | Keep the journal insert, review update, claim, and event in the existing transaction. |
| `Accounting` / `JournalEntry` | Candidate lookup and posted source fingerprint. | Persist the posting-time digest; PostgreSQL uniqueness is the race-safe guard. |
| `Storage` | Provider-neutral reads/writes for original bytes. | Backfill and runtime flows use the facade; no direct bucket access from UI/domain code. |
| PostgreSQL | Authoritative scoped metadata and posting uniqueness. | Partial unique index is per user and excludes null legacy hashes. |

## Duplicate-match order

1. Exact same-user source-document SHA-256: strong, blocking match; display “same uploaded file” and link to the existing entry.
2. Existing `(user, issuer, invoice number)` match: strong, blocking match.
3. Existing exact `(issuer, date, amount, currency)` tuple: possible duplicate; preserve the current warning and explicit confirmation flow.

If a candidate matches more than one rule, show it once and display the strongest applicable reason. A null fingerprint never matches. A digest from a different user is never queried or shown.

## Backfill boundary

The schema migration only adds columns and indexes. A separate idempotent task reads each existing object's bytes through `ZaimuTomo.Storage`, computes `documents.content_sha256`, and copies the corresponding value to posted journal entries. It reports inaccessible objects and same-user journal collisions. The partial unique index is created only after preflight; collisions require human ledger review. No document bytes are sent to OCR/LLM again, and no ledger row is automatically removed.
