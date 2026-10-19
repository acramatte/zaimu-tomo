# ZaimuTomo architecture

A lightweight [arc42](https://arc42.org) description of ZaimuTomo, read top-down:
what the system is for, what it talks to, how it is built, how it runs, and why
it looks the way it does. Infrastructure and day-2 operations have their own
pages: [deployment.md](deployment.md), [operations.md](operations.md), and
[configuration.md](configuration.md).

> Keep this file true. When a change alters a context, a flow, a table, a queue,
> an external service, or a deployment unit, update the matching section in the
> same commit. See [docs/README.md](README.md#keeping-the-docs-current).

---

## 1. Introduction and goals

ZaimuTomo (財務の友, "finance friend") is a personal-finance and bookkeeping web
application. The user uploads invoices and receipts. The system reads them with
OCR and LLMs, and the user approves the result before anything enters the books.

Main capabilities:

| Capability | Summary |
|---|---|
| Document intake | Upload invoices and receipts (PDF, images), stored privately in S3-compatible object storage. |
| AI extraction | OCR to markdown (Mistral), LLM extraction of invoice fields, and a second LLM pass that checks the fields are grounded in the document. |
| Human review | Approve, amend, or reject each extraction. Nothing is booked without sign-off. |
| Bookkeeping | An approved or amended invoice becomes a journal entry. The user then assigns a category and a need/want label, and can mark tax deductibility. |
| Wealth tracking | Financial accounts (cash, savings, investment) with balance snapshots over time. |
| Insight | Dashboard, activity feed, and monthly and year-to-date spending views. |

### Quality goals

| Priority | Goal | What it means here |
|---|---|---|
| 1 | **Correct books** | AI output is a proposal. Only human-reviewed data becomes a journal entry, and every review decision is logged. |
| 2 | **No lost work** | An accepted upload always gets processed or ends in a visible failure the user can retry. Jobs survive restarts and deploys. |
| 3 | **Privacy** | Financial documents stay on self-hosted infrastructure. The app is reachable only over a VPN. Third parties receive only what they need (OCR and LLM calls). |
| 4 | **Low operating cost and simplicity** | One Phoenix monolith, one Postgres, one object store, on one VPS. No separate job broker or microservices. |
| 5 | **Swappable AI** | OCR, extractor, and verifier backends are selected by configuration, so models can change without code changes. |

### Stakeholders

| Who | Expectation |
|---|---|
| Owner/operator (single developer and primary user) | Understands and can operate the system a year from now from these docs. |
| AI coding agents | Find architecture and conventions quickly, and keep these docs current (see `AGENTS.md`). |

---

## 2. Constraints

- **Stack:** Elixir 1.20 / OTP 28, Phoenix 1.8 with LiveView, Ecto with PostgreSQL 18, Tailwind v4, and esbuild. HTTP calls go through `Req`.
- **Single deployable:** one OTP release in one container, deployed with Kamal 2 to a single VPS.
- **Network:** the app is not exposed on the public internet. Users reach it over WireGuard, and only SSH is public.
- **Background work:** Oban OSS (no Pro features). The queue lives in the same Postgres database.
- **Object storage:** must stay provider-neutral (generic `S3_*` config and SigV4 over `Req`). RustFS is self-hosted today.
- **OCR provider:** Mistral Document OCR is the only OCR implementation.
- **License:** MIT; the source is public. Secrets and host details never go into git.

---

## 3. Context and scope

```mermaid
flowchart LR
    user(["User<br/>browser over VPN"])
    zt["ZaimuTomo<br/>Phoenix release"]
    pg[("PostgreSQL<br/>self-hosted")]
    s3[("RustFS<br/>S3-compatible, self-hosted")]
    mistral["Mistral<br/>Document OCR API"]
    llm["LLM backends<br/>Nous Research (prod)<br/>Mistral / FastFlowLM / Ollama"]
    typesafe["TypeSafe Jev<br/>optional shadow verifier"]
    langfuse["Langfuse<br/>optional prompts + traces"]

    user -->|LiveView over HTTP/WebSocket| zt
    zt --> pg
    zt -->|signed S3 requests| s3
    zt -->|document file| mistral
    zt -->|OCR markdown| llm
    zt -->|OCR markdown + extracted fields| typesafe
    zt -->|prompt fetch, OTel traces, feedback scores| langfuse

    classDef ext fill:#fdf4ff,stroke:#a21caf,color:#701a75
    classDef opt fill:#f8fafc,stroke:#64748b,stroke-dasharray:4 3,color:#334155
    class mistral,llm ext
    class typesafe,langfuse opt
```

| Neighbour | Direction | Data that leaves the system | Required? |
|---|---|---|---|
| Browser | in | — | yes |
| PostgreSQL | internal | all relational data and the Oban job table | yes |
| RustFS (S3 API) | internal | original document bytes | yes |
| Mistral OCR | out | the uploaded document file | yes, to process documents |
| Extractor and verifier LLM | out | OCR markdown and extracted fields | yes. In local dev, FLM or Ollama keep it on the machine. Prod sends it to a third-party inference provider (Nous Research by default). |
| TypeSafe | out | OCR markdown and extracted fields | no. Enabled by `TYPESAFE_API_KEY`. |
| Langfuse | out | prompts, traces, and user feedback scores | no. Enabled by `LANGFUSE_*` keys. Local prompt fallbacks exist. |

The browser never talks to object storage or AI providers directly. ZaimuTomo
mediates every access.

---

## 4. Solution strategy

- **Modular monolith.** Phoenix contexts (`lib/zaimu_tomo/*`) own domain logic. LiveViews (`lib/zaimu_tomo_web/live/*`) are thin, and every user-facing query is scoped by `%Accounts.Scope{}`.
- **Durable, transactional jobs.** A document row and its OCR job are inserted in the same Postgres transaction (`Ecto.Multi` plus `Oban.insert`), so an upload cannot exist without its job. Oban retries transient failures and Lifeline rescues jobs orphaned by crashes or deploys.
- **Append-only processing history.** Every terminal processing attempt appends an `extracted_content` row. Retries supersede earlier rows instead of mutating them.
- **Human in the loop.** AI output feeds a review queue. Journal entries are created only from approved or amended decisions, and decisions are audited in `event_logs`.
- **Defence against AI errors.** A second "verifier" LLM checks grounding. An optional independent verifier (TypeSafe) runs in *shadow mode* to gather comparison data without affecting results.
- **Configuration over code for providers.** S3 endpoint, LLM backend, and model per role are all runtime environment variables.
- **Self-hosted by default.** Postgres and RustFS run beside the app as Kamal accessories on the same host.
- **Real-time UI.** Phoenix PubSub broadcasts processing and review events to LiveViews.

---

## 5. Building block view

### Level 1 — the release

```mermaid
flowchart TB
    web["<b>ZaimuTomoWeb</b> · lib/zaimu_tomo_web<br/>Router + UserAuth · LiveViews · Controllers"]
    core["<b>Domain contexts</b> · lib/zaimu_tomo<br/>Accounts · Documents · Review · Accounting<br/>FinancialAccounts · Activity"]
    oban[["<b>Oban</b><br/>queues: documents, typesafe"]]
    proc["<b>DocumentProcessing</b> + TypeSafeVerification<br/>OCRJob · Worker · Recovery"]
    adapters["<b>Infrastructure adapters</b><br/>Storage (S3 / Memory) · DocumentOCR · LLMClient<br/>TypeSafeClient · Langfuse"]
    repo[("Repo → PostgreSQL")]

    web -->|"Scope-first calls"| core
    core -->|"enqueue in the upload txn"| oban
    oban --> proc
    proc -->|"review decision"| core
    core --> adapters
    proc --> adapters
    core --> repo
    proc --> repo
```

| Building block | Path | Responsibility |
|---|---|---|
| `Accounts` | `lib/zaimu_tomo/accounts*` | Users, sessions and tokens (phx.gen.auth), `Scope`, and per-user settings (display name, base currency). |
| `Documents` | `lib/zaimu_tomo/documents*` | Scoped document CRUD. Stores uploads and fingerprints their exact bytes (`store_upload/2`, `Fingerprint`), creates a document and its OCR job atomically, deletes the object after the row is deleted, and owns the fingerprint `FingerprintBackfill`. |
| `DocumentProcessing` | `lib/zaimu_tomo/document_processing*` | OCR → extraction → verification pipeline (`OCRJob`, `Worker`), processing state, retry, stuck-document `Recovery`, and `ErrorClassification`. |
| `TypeSafeVerification` | `lib/zaimu_tomo/type_safe_verification*` | Optional shadow verification job on the `typesafe` queue. |
| `Review` | `lib/zaimu_tomo/review*` | One `ReviewDecision` per extraction (pending → approved / amended / rejected / failed), the `EventLog` audit trail, and Langfuse feedback scores. |
| `Accounting` | `lib/zaimu_tomo/accounting*` | Journal entries from decisions, duplicate-invoice detection (`duplicate_check/3`: exact source file, invoice number, and field tuple), posting (category plus need/want), tax deduction claims, and spending aggregates. |
| `FinancialAccounts` | `lib/zaimu_tomo/financial_accounts*` | Accounts and balance snapshots, net worth by currency. |
| `Activity` | `lib/zaimu_tomo/activity.ex` | A read model assembling each document's current workflow state for the feeds. |
| `Storage` | `lib/zaimu_tomo/storage*` | Provider-neutral facade (`put/get/head/delete/read`) with S3 and in-memory adapters, plus migration and verification tooling. |
| `LLMClient` | `lib/zaimu_tomo/llm_client.ex` | Per-role (extractor and verifier) backend and model resolution through ReqLLM, and response parsing and validation. |
| `Langfuse` | `lib/zaimu_tomo/langfuse.ex` | Prompt fetch (with built-in local fallbacks), OpenTelemetry spans, and feedback scores. |
| `Release` | `lib/zaimu_tomo/release.ex`, `rel/overlays/bin/*` | Release-time commands: migrate, rollback, S3 migration and verification, stuck-document recovery, and the document fingerprint backfill. |

### Level 2 — document processing

| Module | Role |
|---|---|
| `DocumentProcessing.OCRJob` | Oban worker (`documents` queue, 5 attempts, 10-minute timeout, unique per `document_id` while live). Decides retry, failure recording, or cancellation. |
| `DocumentProcessing.Worker` | One attempt: download the object to a temp file → `DocumentOCR` → `LLMClient.extract_invoice` → `LLMClient.verify_extraction` → persist. Persists success only. |
| `DocumentProcessing.ErrorClassification` | Classifies each error as `:transient` or `:permanent`, and produces bounded, body-free summaries. |
| `DocumentProcessing.Recovery` | Finds documents with no extraction and no live job, and re-enqueues them. |
| `ObanFailureLogger` | Telemetry handler that logs failed attempts without payloads. |

---

## 6. Runtime view

### 6.1 Upload → extraction → review → journal entry

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant LV as LiveView
    participant S3 as RustFS
    participant DB as Postgres
    participant J as OCRJob (Oban)
    participant M as Mistral OCR
    participant L as Extractor / Verifier LLM

    U->>LV: upload file
    LV->>S3: Documents.store_upload: SHA-256 of the bytes,<br/>PUT the same bytes to documents/<uuid>.<ext>
    LV->>DB: txn: insert document (with content_sha256) + oban job
    Note over LV,S3: on insert failure the object is deleted
    J->>DB: fetch document
    J->>S3: GET to temp file
    J->>M: OCR → markdown
    J->>L: extract fields (currency hint = user base currency)
    J->>L: verify grounding
    J->>DB: txn: lock document, append extracted_content,<br/>create pending review_decision, enqueue TypeSafe (optional)
    J-->>LV: PubSub document_processing:success
    U->>LV: approve / amend / reject (+ explicit file-reuse confirmation)
    LV->>DB: txn: update review_decision, create journal_entry<br/>(source_document_sha256 snapshot) + tax claim + event_log
    Note over LV,DB: a duplicate rolls the transition back: same issuer + number,<br/>or the same source file without a confirmed reuse (unique indexes).<br/>Soft issuer/date/amount/currency matches and confirmable file<br/>matches are refused before posting until the reviewer confirms
    U->>LV: assign category + need/want → posted
```

### 6.2 Failure, retry and recovery

- **Transient error** (timeouts, 408, 429, 5xx, transport errors) on a non-final attempt: the job returns `{:error, summary}` and **persists nothing**. Oban backs off and retries.
- **Permanent error**, or a transient error on the final attempt (5): the job appends one `failed` `extracted_content` row and a `failed` review decision, broadcasts `document_processing:failed`, and completes.
- **Concurrency safety:** every terminal write locks the document row and checks that the latest extraction is still the one expected when the job was enqueued. Otherwise it cancels with `:already_processed`.
- **Crash or deploy mid-run:** `Oban.Lifeline` moves `executing` jobs back after 30 minutes.
- **User retry:** `DocumentProcessing.retry_document/2` re-enqueues documents in the `:failed` or `:stuck` state. The new run supersedes the old row, which stays as history.
- **Operator recovery:** `bin/recover_stuck_documents` (see [operations.md](operations.md#stuck-documents)).

```mermaid
stateDiagram-v2
    [*] --> processing: upload (job enqueued)
    processing --> extracted: success row
    processing --> failed: permanent / final attempt
    processing --> stuck: job lost
    failed --> processing: retry
    stuck --> processing: retry or recover
    extracted --> pending_review
    pending_review --> approved
    pending_review --> amended
    pending_review --> rejected
    approved --> journal_entry
    amended --> journal_entry
    journal_entry --> posted: category + need/want
```

### 6.3 TypeSafe shadow verification (optional)

When `TYPESAFE_API_KEY` is set, the success transaction also enqueues a
`TypeSafeVerification.Worker` job on the `typesafe` queue, isolated by a
savepoint so an enqueue failure never rolls back the extraction. The job re-reads
the OCR markdown from the stored row; job args never contain financial text. It
writes per-field error probabilities to
`extracted_content.analysis.verification.typesafe_shadow` and never changes the
authoritative verification result. It is fail-open: provider errors are recorded
on the row and the job completes.

---

## 7. Deployment view

```mermaid
flowchart LR
    dev(["Developer machine<br/>kamal deploy"])
    ghcr[("GHCR<br/>container registry")]
    subgraph vps["VPS (Docker)"]
        nginx["nginx<br/>VPN interface"]
        proxy["kamal-proxy<br/>VPN-only bind"]
        app["zaimu-tomo app<br/>Phoenix release :4000"]
        db[("zaimu-tomo-db<br/>postgres:18")]
        rustfs[("zaimu-tomo-rustfs<br/>RustFS")]
    end
    user(["User on WireGuard"])
    backup[("Off-host backup storage")]

    dev -->|build + push| ghcr
    dev -->|SSH| vps
    ghcr --> app
    user --> nginx --> proxy --> app
    app --> db
    app --> rustfs
    rustfs -. nightly rclone export .-> backup
    db -. nightly pg_dump .-> backup
```

| Environment | How it runs |
|---|---|
| Local dev | `docker compose` for Postgres and RustFS, then `mix phx.server`. Local LLMs (FastFlowLM or Ollama) or cloud backends. |
| Test / CI | GitHub Actions (`.github/workflows/ci.yml`): Postgres service, `mix compile --warnings-as-errors`, `mix test`. The in-memory storage adapter and Oban `testing: :manual` are used. RustFS integration tests are opt-in (`RUN_INTEGRATION=true`, Testcontainers). |
| Amp orb | `.agents/setup` and `.agents/resume` prepare a disposable dev sandbox (orb only, never production). |
| Production | Kamal 2 on a single VPS, as above. Details: [deployment.md](deployment.md). |

---

## 8. Crosscutting concepts

### Data model

```mermaid
erDiagram
    users ||--o{ documents : owns
    users ||--o{ financial_accounts : owns
    documents ||--o{ extracted_content : "processing attempts (append-only)"
    extracted_content ||--|| review_decisions : "one decision"
    review_decisions ||--o{ event_logs : "audit trail"
    review_decisions ||--o| journal_entries : "approved/amended"
    journal_entries ||--o| tax_deduction_claims : ""
    financial_accounts ||--o{ balance_snapshots : ""
```

- `documents` stores `filename` (original name), `object_key` (`documents/<uuid>.<ext>`), and `content_sha256` (SHA-256 of the exact uploaded bytes, lowercase hex; null for legacy rows until the backfill reads them). The bytes live only in object storage. Replacing the object replaces the digest.
- `extracted_content` holds `extracted_data` (an embedded schema), `raw_llm_response`, an `analysis` map (verification and TypeSafe shadow results), `status` (`success` or `failed`), `error_details`, and the Langfuse `trace_id`.
- Money is stored in integer cents with an ISO currency code. Each user has a `base_currency` (default CHF), which is snapshotted into each OCR job as the currency hint.
- `oban_jobs` lives in the same database. Finished jobs are pruned after 7 days.
- Deleting a document that has a posted journal entry is blocked by a foreign key.
- A partial unique index on `journal_entries (user_id, lower(btrim(issuer)), lower(btrim(invoice_number)))` blocks posting the same numbered invoice twice per user. An unnumbered invoice matching an existing entry's exact `(issuer, date, amount, currency)` tuple is a soft match that requires explicit reviewer confirmation to post. See `Accounting.duplicate_candidates/2`.
- `journal_entries.source_document_sha256` is an immutable posting-time copy of the source document's `content_sha256`; `source_file_reuse_confirmed` (default false) marks a posting the reviewer explicitly confirmed as a reuse of the same file. The partial unique index `journal_entries (user_id, source_document_sha256) WHERE source_document_sha256 IS NOT NULL AND NOT source_file_reuse_confirmed` allows one unconfirmed posting per file per user. `Accounting.duplicate_check/3` ranks matches as same file > invoice number > same details; a file match is confirmable only when no field rule also matches (the tuple is compared against the file-matched entries even for numbered invoices). Confirmations are logged as `source_file_reuse_confirmed` events with the matched entry IDs. Fingerprints are user-scoped, redacted from inspect output, and never rendered or sent to an AI provider. Only `FingerprintBackfill` may set them on existing entries; there is no immutability trigger on `journal_entries` yet, and any future one must run after the backfill or allow it.

### Multi-tenancy and authorization

Every context function takes `%Accounts.Scope{}` first and filters by
`scope.user.id`. Routes requiring login live in `live_session :require_authenticated_user`.
Unscoped functions exist only for maintenance tasks (storage verification,
stuck recovery, fingerprint backfill) and say so in their docs.

### Background jobs (Oban)

| Queue | Worker | Concurrency (env) | Attempts | Notes |
|---|---|---|---|---|
| `documents` | `DocumentProcessing.OCRJob` | `OBAN_DOCUMENTS_CONCURRENCY` (2) | 5 | Unique per document while live. 10-minute timeout. |
| `typesafe` | `TypeSafeVerification.Worker` | `TYPESAFE_MAX_CONCURRENCY` (2) | 3 | Fail-open shadow run. |

Plugins: `Oban.Pruner` (7 days) and `Oban.Lifeline` (30 minutes, which must exceed
the OCR timeout). Rules: job args are self-contained commands resolved at
enqueue time, and they never carry document text or provider payloads.

### AI pipeline configuration

OCR always uses Mistral. The extractor and verifier each take an explicit
`backend` (`nousresearch | mistral | flm | ollama`) and `model`. There is no
fallback. Prompts (`extract-invoice`, `verify-extraction`) come from Langfuse
(label `production`) when Langfuse is enabled, and from built-in local templates
otherwise. See [local-ai.md](local-ai.md) and [configuration.md](configuration.md).

### Observability

- **Tracing:** OpenTelemetry spans per document (`process-invoice` → extraction, verification, TypeSafe shadow), exported to Langfuse when it is enabled. The trace ID is stored on the extraction, so user 👍/👎 feedback becomes a Langfuse score.
- **Logs:** tagged prefixes (`[OCR]`, `[TypeSafe]`). Failures are logged as bounded summaries, never as OCR text or provider bodies.
- **Health:** `GET /health` and `/up` (no session or auth), used by kamal-proxy and the Docker `HEALTHCHECK`.
- **LiveDashboard:** dev only (`/dev/dashboard`).

### Security and privacy

- VPN-only exposure, private bucket, and app-mediated preview and download (`DocumentController`, inline only for PDFs and images).
- Secrets come from environment variables at runtime (`config/runtime.exs`), supplied by Kamal from `.kamal/secrets`, which is not committed.
- Financial text is kept out of `oban_jobs`, logs, and error summaries.

### Real-time UI

PubSub topics: `user:<id>:documents`, `document_processing:success|failed`,
`invoice_review:completed`, and `user:<id>:financial_accounts`. LiveViews
subscribe in `mount/3` when connected.

### Testing

ExUnit with the SQL sandbox. Storage uses the Memory adapter, HTTP uses
`Req.Test` stubs, and Oban runs in manual testing mode. Run `mix precommit`
before committing (compile with warnings as errors, unlock unused deps, format,
test). Credo is available.

---

## 9. Architecture decisions

Short decision records, newest last. Add one when a change alters structure,
infrastructure, or a cross-cutting rule. Older, longer feature-level reasoning
is in [`specs/`](../specs/README.md).

| # | Date | Decision | Why / consequences |
|---|---|---|---|
| D1 | 2026-01 | Phoenix LiveView monolith with phx.gen.auth scopes | One deployable, server-rendered real-time UI. All data is scoped per user. |
| D2 | 2026-03 | Persist every extraction attempt as a row; one review decision per extraction | Keeps history, and humans approve before booking. See `specs/001`, `specs/002`. |
| D3 | 2026-05 | Journal entries only from approved or amended decisions | AI never writes to the books directly. |
| D4 | 2026-06 | Kamal 2 on a single VPS, app reachable only over WireGuard | Low cost, private by default. Postgres runs as a Kamal accessory. |
| D5 | 2026-08 | Per-role LLM backends (extractor and verifier) selected by env, with no fallback | Models can be swapped or mixed (local and cloud) without code changes. Misconfiguration fails loudly. |
| D6 | 2026-08 | Document bytes in S3-compatible storage (self-hosted RustFS), with a provider-neutral `Storage` facade | Decouples bytes from the release. A later provider switch is config only. See `specs/003`. |
| D7 | 2026-09 | TypeSafe Jev as a *shadow* verifier | Collects independent per-field error probabilities without affecting outcomes until it is trusted. |
| D8 | 2026-09 | Replace fire-and-forget `Task` OCR with durable Oban jobs, enqueued in the upload transaction | Uploads can't lose their job. Retries, Lifeline rescue, user retry, and operator recovery. The TypeSafe shadow also moved to Oban. |
| D9 | 2026-10 | Add `stream_data` (test-only) for property-based tests on pure, boundary-heavy logic (currency normalization, error-retry classification, changeset validity, aggregation sums) | Generates and shrinks adversarial inputs instead of relying only on hand-picked examples; already caught an Ecto blank-string edge case in `Currency.normalize_and_validate/2`. DB-backed properties cap `max_runs` explicitly to bound CI time; `config :stream_data, max_runs` is lower locally, higher in CI (`CI=true`, set by GitHub Actions by default). |
| D10 | 2026-08 | Duplicate invoice detection: DB-enforced unique index, plus the journal entry in the same transaction as the review decision | A numbered invoice (same user, issuer, invoice number) cannot post twice; the database enforces it regardless of code path. An unnumbered exact `(issuer, date, amount, currency)` match warns and needs explicit confirmation. Posting the journal entry, tax claim, and event log now happens in the same `Ecto.Multi` as the decision update, so a duplicate or a failed audit write rolls the whole transition back — closing the gap in §11. |
| D11 | 2026-10 | Exact-byte SHA-256 fingerprints as an OCR-independent duplicate signal, copied to the journal entry at posting and enforced by a per-user partial unique index over unconfirmed postings | Re-uploading identical bytes is caught even when OCR/LLM reads different fields. A unique constraint cannot span document → extraction → review → entry, so the digest is snapshotted on the entry. Legitimately reused files (QR-bills, standing slips) post only with an explicit per-posting confirmation, recorded on the entry and in the event log. Legacy rows are filled by an online, idempotent backfill through the `Storage` facade, never by a migration. See `specs/004`. |
| D12 | 2026-10 | Upgrade to Elixir 1.20 (OTP unchanged at 28) | Elixir 1.20 completes zero-annotation type inference across all constructs, so the existing `mix compile --warnings-as-errors` CI gate now also catches unreachable clauses and dead code for free, no specs or Dialyzer required. Surfaced and removed 3 pre-existing dead branches (`review.ex`, `llm_client.ex`, `langfuse.ex`) that the 1.19 compiler couldn't see. First step toward the CI reliability work tracked for direct-to-main pushes; a complementary nightly Dialyzer job (whole-program success typing) is still planned separately. |
| D13 | 2026-10 | Split CI into `lint` / `test` / `security-audit` jobs; `mix credo --strict` and `mix hex.audit` run on every push but are advisory (non-blocking), with a separate nightly workflow re-running the audit so a CVE disclosed on a quiet day still gets caught | First step of hardening CI as the real safety net for pushing straight to `main` with less manual review. Credo and the audit aren't required checks yet because both already have a pre-existing backlog (51 Credo issues; `hackney` pinned to a vulnerable 1.x line by a test-only dependency) unrelated to any one change — see §11. `mix hex.audit` found 6 live advisories in locked dependencies; the `bandit` ones were fixed by a routine version bump in the same change, `hackney`'s needs a dependency change tracked separately. |
| D14 | 2026-10 | Add Dialyzer (dialyxir) as a nightly, advisory-only CI job rather than a required per-push check | Whole-program success typing complements the Elixir 1.20 compiler's own type inference (D12) by also checking across the OTP/dependency boundary, but PLT builds are too slow for a per-push gate. First run found 10 findings: 3 duplicated dead code already fixed by the Elixir 1.20 upgrade; 5 are a well-known Dialyzer/`Ecto.Multi` opaque-`MapSet` false positive; 2 (`storage/s3.ex`) are a `File.stream!/2` success-typing gap verified benign directly in `iex` before suppressing. All 7 non-duplicate false positives are listed individually in `.dialyzer_ignore.exs` with the reasoning, not blanket-ignored, so a genuinely new finding in the same file still surfaces. Also added missing `@type t :: %__MODULE__{}` to `ExtractedData` and `ExtractedContent.ExtractedContent` (matching the convention already used in `Document`/`ReviewDecision`), which cleared 9 separate `unknown_type` findings and makes every existing `@spec` referencing them actually checked going forward. |

---

## 10. Quality requirements

| Scenario | Expected behaviour |
|---|---|
| The app is redeployed while a document is being processed | Lifeline rescues the job and the document is processed exactly once (no duplicate terminal rows). |
| The LLM provider returns 429 or 5xx | Retried with backoff up to 5 attempts, then one visible failure the user can retry. |
| TypeSafe is down or slow | Extraction is unaffected. The shadow result records a failure. |
| A user opens another user's document ID | Not found (scoped query). |
| The VPS is lost | Restore from the off-host object export plus the Postgres dump, then `bin/verify_storage` reports zero missing objects. |
| Switching the LLM model | Env change and redeploy only. |
| The same file is uploaded and approved twice concurrently | At most one journal entry commits (unique index); the other review rolls back and stays pending. |

---

## 11. Risks and technical debt

| Item | Notes |
|---|---|
| Legacy upload volume | `zaimu_tomo_uploads` is still mounted (`config/deploy.yml`, `Dockerfile`) from the pre-S3 migration. Remove it after the restore check is recorded (see [operations.md](operations.md#legacy-upload-volume)). |
| Single host | App, DB, and object store share one VPS. Backups are the only DR mechanism. |
| No production mailer | `runtime.exs` configures no Swoosh adapter for prod, so email-based auth flows (confirmation, magic links) don't deliver in production. |
| Shared S3 credential | The app's S3 key is the RustFS root credential. Per-application credentials are not yet introduced. |
| `force_ssl` off | HTTP behind the VPN is by design. Enable `FORCE_SSL` at build time if the app is ever exposed publicly. |
| Fingerprint coverage of legacy postings | Exact-file protection covers historical entries only after `bin/backfill_document_fingerprints` reports complete coverage. Missing objects and unresolved same-user collisions stay null and are not protected (see [operations.md](operations.md#document-fingerprint-backfill)). |
| Confirmed reuses are not DB-constrained | A confirmed file reuse is excluded from the unique index; the "no field match" condition is checked in the posting transaction, not by a constraint, so two simultaneous postings by the same user could both pass it. |
| `hackney` pinned to a vulnerable 1.x line | `testcontainers` (test-only) requires `~> 1.20`, but hackney's maintainers moved straight from 1.x to a 4.x line with no further 1.x patch releases, so `mix hex.audit` permanently flags 4 open CVEs (1 HIGH) on this transitive dependency until `testcontainers` (or its `tesla`/hackney requirement) supports hackney 4.x. Flagged by the new `security-audit` CI job and nightly audit; not fixed here since forcing hackney 4.x would likely break `testcontainers`. |
| `mix credo --strict` backlog | Added to CI as advisory/non-blocking (§9 D13) because it already reports 51 pre-existing issues (mostly alias ordering and nested-module aliasing) unrelated to any one change. Needs a dedicated cleanup pass before it can become a required check. |

---

## 12. Glossary

| Term | Meaning |
|---|---|
| Extraction / extracted content | One processing attempt's result for a document (success or failed). |
| Extractor / verifier | The two LLM roles: extract the invoice fields, then check they are grounded in the OCR text. |
| Shadow verification | TypeSafe Jev run whose results are stored for comparison but never used for decisions. |
| Review decision | A human verdict on an extraction: pending, approved, amended, rejected, or failed. |
| Journal entry | A booked expense. `uncategorized` until the user posts it with a category and need/want label. |
| Stuck document | Has no extraction row and no live OCR job. |
| Currency hint | The user's base currency, snapshotted when the job is enqueued, to guide extraction. |
| Accessory | A Kamal-managed sidecar container (Postgres, RustFS). |
| Orb | An Amp cloud sandbox used for agent development. |
