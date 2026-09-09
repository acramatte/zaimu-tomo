# Feature Specification: Document Matters and Evidence-Grounded Briefs

**Feature branch**: `feat/document-matters` (implementation; this document branch is `docs/document-matters-spec`)
**Created**: 2026-08-31
**Status**: Proposed
**Input**: Users need to understand invoices, tax letters, reconciliations, reminders, and correspondence in the context of related prior documents. The first release deliberately produces a fixed, cited document brief rather than free-form chat.

## 1. Context and problem

ZaimuTomo currently stores document metadata, OCR/LLM-extracted invoice facts, human review decisions, journal entries, and tax-deduction claims. The document pipeline turns an uploaded file into OCR markdown in `ZaimuTomo.DocumentProcessing.Worker`, but does not persist that markdown. The application can therefore show individual invoice fields but cannot later explain *why* a document matters, search its source language, or cite passages that support a conclusion.

Users receive documents that form a sequence rather than isolated invoices. A Swiss-tax example often includes a prior-year final assessment/reconciliation and separate current-year provisional instalments. These may share issuer and taxpayer but have different periods, payment obligations, and legal roles. The product must make that distinction visible and traceable.

## 2. Goals and non-goals

### Goals

- **G1 — Explain a document in context.** After processing, a document has a generated brief that explains its apparent role, current obligation, likely relationships, and known unknowns.
- **G2 — Make every material claim traceable.** A brief cites the exact source document and OCR text excerpt that supports each material conclusion.
- **G3 — Build durable document matters.** Users can group related documents into a matter and confirm or reject suggested relationships.
- **G4 — Preserve ownership boundaries.** Every retrieval, relationship, brief, and route is constrained by `current_scope.user`; inaccessible documents behave as missing.
- **G5 — Separate machine suggestion from user confirmation.** Machine-generated classifications and links are never silently authoritative and never change accounting, payment, or tax-claim state.
- **G6 — Use a simple, auditable retrieval foundation.** Start with identifiers, reviewed facts, PostgreSQL full-text search, and confirmed relationships. Add vector retrieval only after measured evidence that this baseline misses relevant material.

### Non-goals

- A free-form conversational chatbot in the first release.
- Automatically paying an invoice, posting a journal entry, changing a tax-deduction claim, or making a legal/tax decision.
- Cross-account household sharing or discovery of another application account's documents.
- A standalone vector database or graph database.
- Replacing the existing OCR, extraction, review, accounting, or tax-claim workflows.
- Claiming that a document is legally binding, paid, settled, deductible, or overdue without source evidence.

## 3. Product decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | The first interaction is a fixed **Document brief**, not a chat input. | It constrains model output and retrieval scope, lowers UI/state complexity, and establishes reusable evidence infrastructure before broad questions are accepted. |
| D2 | A brief is generated after successful document processing and shown as a **draft explanation**. | Users receive value immediately; facts derived from an unreviewed extraction are visibly unverified. |
| D3 | OCR markdown is persisted as derived evidence, separate from Langfuse. | Langfuse is observability, not the user's durable, private source record. Citable retrieval requires app-owned text. |
| D4 | Relationships are stored in PostgreSQL tables, with a user-owned matter as the main grouping abstraction. | Referential integrity, ownership filtering, timeline queries, and auditability fit relational storage. A graph database is unnecessary. |
| D5 | Retrieval is hybrid but deterministic-first: exact identifiers, structured fields, confirmed links, then PostgreSQL FTS. | Financial correspondence contains high-signal identifiers and dates; this is more explainable than semantic similarity alone. |
| D6 | The explainer returns structured output with mandatory citations and explicit unknowns. | The UI can render only evidence-backed assertions and distinguish confirmed facts from inference. |
| D7 | Vectors are deferred. If required, use `pgvector` in the existing PostgreSQL database for text chunks. | One authorization, backup, and foreign-key boundary; vectors improve recall but never replace identifiers, FTS, or citations. |
| D8 | “Different user” means a different document subject within the signed-in user's own archive. | Current data access is per application user. The feature can label an obligation's person/entity without expanding authorization. |

## 4. User stories and acceptance scenarios

### US1 — Read an automatic brief (P1)

As a user, I want to open a processed document and understand what it appears to be, what it asks of me, and how confident the system is, so I do not have to decipher it alone.

**Acceptance scenarios**:

1. Given a successfully processed document, when I open its document page, then I see a clearly labelled **Draft explanation**.
2. The brief includes document type, issuer, subject label when found, tax/service period when found, payment obligations, and explicit unknowns.
3. A document without sufficient source evidence renders “I could not determine this from the uploaded document” rather than a plausible answer.
4. The brief never changes an accounting, review, payment, or tax-claim record.

### US2 — Trace the explanation to evidence (P1)

As a user, I want each material conclusion to identify its source, so I can verify the explanation against the original documents.

**Acceptance scenarios**:

1. Every current obligation, period classification, and relationship statement displays one or more citations.
2. A citation identifies the document, excerpt, and support level (`confirmed` or `inferred`).
3. Selecting a cited document opens the existing authenticated preview/download path, subject to ownership checks.
4. If a cited source document is deleted, the associated relationship/brief is invalidated or regenerated; the UI never links to an inaccessible file.

### US3 — Inspect a matter timeline (P1)

As a user, I want related documents grouped into a timeline, so I can distinguish a prior-year reconciliation from a current-year instalment.

**Acceptance scenarios**:

1. Given a prior-year final assessment and current-year provisional bills, the system can present them in one matter with their distinct periods and roles.
2. The timeline orders source documents by their document date when known, otherwise upload date, and marks the ordering basis.
3. A relationship suggestion is visibly distinct from a user-confirmed link.
4. The user can create a matter, link/unlink a document, and confirm/reject a suggestion without modifying the source document's reviewed invoice facts.

### US4 — Correct the system (P1)

As a user, I want to correct document type, subject, period, and relationship suggestions, so future briefs improve without hiding the original machine output.

**Acceptance scenarios**:

1. A user can confirm or override an interpretation field and records the change's source and timestamp.
2. A user can confirm, reject, or manually create a relationship.
3. Rejected suggestions do not return as active suggestions for the same source/target/relation combination unless new evidence appears.
4. User corrections take precedence over machine suggestions in retrieval and brief generation.

### US5 — Surface only relevant archive evidence (P1)

As a user, I want the system to search only my own relevant documents, so private financial correspondence is not exposed or confused.

**Acceptance scenarios**:

1. All document, text, matter, relationship, and citation queries include the current scope's user ID at the query boundary.
2. A guessed foreign ID returns not found, not a relationship or authorization disclosure.
3. Retrieval has fixed candidate and excerpt limits before any LLM call.
4. Tests prove that a user cannot retrieve another user's source text, matter, citation, or relationship.

## 5. Required document brief contract

The LLM-facing response is structured and validated before rendering. The initial contract is:

```text
summary: string
current_document_role: one of the documented roles
subject_label: string | nil
issuer: string | nil
periods: list of period objects
current_obligations: list of obligation objects
relationship_explanations: list of cited relationship statements
unknowns: list of strings
evidence: list of citation objects
```

A citation object has at least:

```text
document_id: integer
text_excerpt_id: integer
claim: string
support_level: confirmed | inferred
```

The application rejects an explanation when a material claim has no valid citation to a scoped source. A failed explanation becomes a durable, user-visible processing state; it is not rendered as a blank “still processing” panel.

## 6. Document categories and relationship vocabulary

Initial document roles:

- `tax_assessment`
- `provisional_tax_bill`
- `reconciliation`
- `reminder`
- `credit_note`
- `payment_confirmation`
- `invoice`
- `correspondence`
- `other`

Initial direct relationships:

- `references`
- `corrects`
- `settles`
- `same_obligation_as`
- `duplicate_of`
- `payment_for`
- `supersedes`

The vocabulary is deliberately descriptive. It is not legal or tax advice, and an implementation must not use a relationship to imply payment, deductibility, or enforceability.

## 7. Privacy, security, and data-retention constraints

- Source OCR text is private financial data. Store it under application database retention rules and never expose it through an unscoped API.
- Continue serving original files through the existing authenticated preview/download controller routes; never return object-store URLs or local paths to the browser.
- Langfuse may retain prompt/response observability under its existing configuration, but its data must not be the only copy of a citation source.
- Keep prompt input bounded to selected excerpts and structured facts. Do not supply the model with the user's entire document archive.
- Retain enough provenance to reproduce an explanation: prompt name/version, role model, retrieval candidate IDs, selected excerpt IDs, and response status. Do not persist hidden chain-of-thought.

## 8. Success criteria

- **SC1**: 100% of rendered material brief claims have a valid source citation owned by the current user.
- **SC2**: A fixture with a 2025 reconciliation and 2026 provisional bill explains that they have different periods and roles; it does not conflate their amounts or obligations.
- **SC3**: A fixture with no payment confirmation produces an explicit unknown rather than asserting payment state.
- **SC4**: A user correction changes future retrieval/brief output while preserving the original machine interpretation for audit.
- **SC5**: No default test makes real LLM, Langfuse, OCR, or storage calls.

## 9. Delivery sequence

1. Evidence foundation: persist OCR text, excerpts, PostgreSQL FTS, and structured interpretation.
2. Matters and relationships: durable grouping, suggestions, user confirmation, timeline.
3. Document brief: bounded retrieval, explainer role, structured cited output, document/matter UI.
4. Evaluation and hardening: fixture corpus, negative tests, telemetry, feedback workflow.
5. Optional semantic retrieval: only after retrieval metrics justify `pgvector`.

Detailed implementation work is in `plan.md` and `tasks.md`; entity contracts are in `data-model.md`.
