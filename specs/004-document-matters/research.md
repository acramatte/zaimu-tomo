# Research and Architecture Decisions: Document Matters

**Date**: 2026-08-31
**Scope**: Design decisions needed before implementation. This is not vendor research and does not claim that a vector extension is installed in the current PostgreSQL deployment.

## 1. Current-system findings

| Finding | Evidence / consequence |
|---|---|
| The OCR worker receives markdown but does not persist it. | `ZaimuTomo.DocumentProcessing.Worker.process/1` calls `DocumentOCR.process/1`, passes markdown to extraction/verification, then stores only extracted JSON, raw OCR-provider response, and verification analysis. A document brief needs its own durable source text. |
| Extracted invoice data is intentionally narrow. | `ExtractedData` has amount, date, number, currency, reason, and issuer. It does not represent taxpayer/subject, assessment reference, period, deadline, document role, or relationship evidence. |
| Existing user review is separate from extraction. | `ReviewDecision` preserves original vs amended data; the new interpretation model must follow the same separation rather than overwrite machine facts. |
| Existing source bytes are private and application-mediated. | Preview/download controller routes are authenticated and source document lookup is scoped. Brief citations must follow this boundary. |
| Current LLM roles are extraction and verification. | Add an `explainer` role; do not overload the verifier, whose job is grounding structured extraction fields against one OCR body. |
| Current scopes are per application user. | “Different user” must mean a subject label within the current account's documents until a separately designed sharing/household authorization model exists. |

## 2. Alternatives considered

### A. Free-form chat first

**Rejected for the first release.**

A generic question input expands the query surface immediately: broad date requests, ambiguous pronouns, payment-status claims, cross-matter questions, multi-turn context, injection attempts in user input, and chat history/persistence. The evidence and retrieval foundation is still needed, so chat-first adds product and safety surface without eliminating foundational work.

**Follow-up path:** Once document briefs demonstrate reliable citations and retrieval, add guided questions first (“Why did I receive this?”, “What changed?”, “Which earlier document does this reference?”). Free input is a later capability.

### B. Automatic document brief first

**Chosen.**

A brief has one known source document, fixed output schema, fixed retrieval budget, and a testable evidence contract. It gives the user immediate value after upload while allowing user confirmation before any relationship becomes authoritative.

### C. Separate vector database from day one

**Rejected.**

The initial document corpus has strong deterministic signals: invoice/assessment/QR references, issuer, subject label, tax/service period, currency, amount, and exact OCR terms. A separate service introduces authentication, operational backups, synchronization/deletion complexity, and less auditable candidate selection before there is a demonstrated recall problem.

### D. PostgreSQL full-text search plus relational retrieval

**Chosen.**

PostgreSQL already owns users, documents, extraction records, review facts, and relationships. Persisted source OCR text plus FTS provides keyword/phrase search; relational joins provide exact identifiers, verified links, and period/issuer matching. Candidate source IDs are straightforward to audit and scope.

### E. PostgreSQL `pgvector` later

**Deferred with a decision gate.**

If evaluation shows that structured matching and FTS fail to retrieve relevant unstructured correspondence, add embeddings at the excerpt level via `pgvector` in the existing database. This should be a measured addition with retrieval metrics and deletion/re-index semantics, not a speculative dependency.

### F. Graph database

**Rejected.**

The initial graph is small and strongly relational: matters, documents, relationships, citations, and user confirmation. PostgreSQL foreign keys and indexed join tables provide the required semantics with simpler authorization and backup operations.

## 3. Retrieval strategy

### 3.1 Candidate generation order

1. **Confirmed direct relationships and matter membership** for the source document.
2. **Exact normalized identifiers**: invoice number, assessment number, customer number, payment/QR reference.
3. **Structured compatibility**: same issuer, subject, document role, tax/service period, and amount where appropriate.
4. **PostgreSQL FTS** against OCR source text for extracted key terms and document-type terms.
5. **Optional later semantic retrieval** only after the above candidates prove insufficient.

Every stage filters on `user_id` before returning IDs. Candidate selection must use a small documented cap, for example 20 documents / 40 excerpts, and final prompt assembly must have a token budget.

### 3.2 Ranking principles

- Exact matching evidence outranks text similarity.
- User-confirmed links outrank machine suggestions.
- A later authoritative document may be a better explanation source, but chronology is shown separately from rank.
- A machine suggestion is never promoted to `confirmed` merely because the LLM repeats it.
- Lack of retrieved proof produces an unknown; it is not a negative conclusion.

## 4. Explainer design

The explainer consumes a bounded evidence pack, not raw database access. Its prompt requires:

- use only supplied evidence;
- cite excerpt IDs for every material claim;
- distinguish confirmed from inferred relationships;
- state unknowns explicitly;
- never assert that something was paid, legally due, deductible, or settled without evidence;
- output only the validated structured schema.

The implementation should use the existing ReqLLM structured-output hardening path: parse native structured output, then the repaired text/object fallback needed by local backends, and validate the final map in an Ecto/embedded schema before persistence. Its test suite must pin Langfuse disabled, preventing real network calls in environments where credentials are present.

## 5. Evaluation corpus

Create hermetic fixtures with persisted OCR text/excerpts, interpretation rows, and document relationships. Minimum cases:

1. **Swiss tax separation**: 2025 final assessment/reconciliation + 2026 provisional bill; brief correctly distinguishes years, roles, and obligations.
2. **Correction**: a credit note corrects an earlier invoice; brief cites both and says what changed.
3. **Duplicate**: same invoice uploaded twice; brief identifies duplicate only when the duplicate context has confirmed it.
4. **Missing source**: a letter refers to an unavailable assessment; brief names the gap rather than fabricating the missing document.
5. **No payment proof**: obligation exists but no payment confirmation; brief reports unknown payment status.
6. **Cross-user isolation**: similarly named documents for two accounts; retrieval and citations never cross scopes.
7. **Prompt-injection text**: OCR body contains instructions to ignore prior instructions; returned brief remains schema-valid and evidence-only.

Metrics to collect before any vector phase:

- source-document recall in the fixture corpus;
- citation coverage: material claims with valid citations / all material claims;
- unsupported-claim count;
- user correction/rejection rate by document role and relationship type;
- percentage of briefs ending in a useful explicit unknown rather than failure.

## 6. Open implementation questions, intentionally resolved

| Question | Resolution |
|---|---|
| Should briefs run before human invoice review? | Yes, but prominently labelled draft/unverified. They cannot create side effects. |
| Should one document belong to multiple matters? | Yes. `matter_documents` has a composite uniqueness per matter/document, not globally per document. This supports a correspondence document that is relevant to an annual matter and a related supplier/account matter. |
| Should user overrides replace machine extraction? | No. Separate versioned rows preserve auditability and make effective precedence explicit. |
| Should extraction data be copied into every matter? | No. Keep source facts in their owning records and retrieve through references. |
| Do citation excerpts need mutable page coordinates? | Initial release uses deterministic text offsets/excerpts. Page-aware coordinates can be added later after validating OCR-provider output stability and preview UX. |
| Does this feature expose a generic search API? | No. Retrieval remains behind scoped contexts and LiveViews until authorization, quotas, and an API contract are designed. |
