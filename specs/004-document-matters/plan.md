# Implementation Plan: Document Matters and Evidence-Grounded Briefs

**Input**: `spec.md`, `data-model.md`, and `research.md`
**Status**: Proposed — no production code in this documentation PR
**Route placement**: all new LiveViews belong inside the existing authenticated `:require_authenticated_user` `live_session` in `lib/zaimu_tomo_web/router.ex`, because every brief, matter, source document, and citation must receive `current_scope` and reject unauthenticated access at the router boundary.

## Phase 0 — Integration and baseline decisions

**Goal:** Begin implementation from a known current base without duplicating active feature work.

1. Fetch `origin` and inspect whether `feat/duplicate-invoice-detection` and `feat/tax-claim-lifecycle` have merged.
2. If either remains unmerged, keep this implementation independent of its migrations and contexts. Do not stack or import them without an explicit dependency decision.
3. Create a dedicated implementation worktree from explicit `origin/main` and a branch such as `feat/document-matters-foundation`.
4. Read the current versions of `Documents`, `DocumentProcessing.Worker`, `LLMClient`, `Langfuse`, `Review`, `Accounting`, private document preview controller, router, and sibling LiveViews before editing.
5. Establish test configuration helpers that pin Langfuse disabled and inject LLM/prompt functions. No default test may call OCR, Langfuse, object storage, or an LLM provider.

**Verify:** clean worktree; `mix compile --warnings-as-errors`; targeted baseline tests pass.

## Phase 1 — Evidence foundation

**Goal:** Persist the source OCR text required to search and cite documents.

1. Generate migrations using Mix generators for `document_texts` and `document_text_excerpts`.
2. Add schemas, changesets, and a scoped `DocumentEvidence` context. The public context takes `%Scope{}` as its first argument for every document lookup/list/query.
3. Update `DocumentProcessing.Worker.persist_and_emit_success/5` so successful OCR creates the extraction plus an app-owned text record from the OCR markdown in one deliberate orchestration flow. Preserve the worker's existing temporary-file cleanup and processing failure behavior.
4. Build deterministic excerpts after persisting the OCR text. Record a documented offset convention and a strict source/excerpt size limit.
5. Add the PostgreSQL FTS migration/index and scoped query functions for exact text/phrase retrieval.
6. Keep source text separate from `raw_llm_response`, `analysis`, and Langfuse traces. Do not retrofit OCR text into raw LLM maps.

**Verify:**

- focused context/worker tests prove a successful OCR result persists text and deterministic excerpts;
- failed OCR persists no fake source text;
- FTS finds a scoped source and cannot find an identical foreign user's source;
- `mix compile --warnings-as-errors` and focused tests pass.

## Phase 2 — Structured document interpretation

**Goal:** Classify a document and extract the facts needed to relate it to other documents.

1. Generate the `document_interpretations` migration and schema per `data-model.md`.
2. Add a `DocumentIntelligence` context that exposes effective interpretation, machine interpretation persistence, and user correction persistence. It owns precedence rules rather than leaving them to templates.
3. Add a distinct `:interpreter` LLM role to `LLMClient` configuration. It returns a validated structured payload for document role, issuer, subject label, references, periods, and obligations.
4. Add a new local/Langfuse-managed `interpret-document` prompt. Include only the source document OCR text; it does not need archive retrieval in this phase.
5. Extend the successful document-processing orchestration to create the interpretation after OCR text persistence. Processing failures become durable interpretation/brief-eligible failure state, not an endlessly pending UI.
6. Add a compact interpretation section to `DocumentLive.Show`, with an explicit draft/unverified label and a correction entry point. Do not add the full brief yet.

**Verify:**

- interpretation schema rejects invalid role/period/obligation shapes;
- prompt/response tests use an injected generator and validate all parsed output;
- a user correction wins effective interpretation while the original machine row remains readable;
- no current invoice review or journal-entry creation behavior changes.

## Phase 3 — Matters and relationships

**Goal:** Let a user build and validate the document graph in a relational, auditable form.

1. Generate migrations/schemas for `financial_matters`, `matter_documents`, and `document_relationships` with database constraints from `data-model.md`.
2. Add a `Matters` context. It owns scoped matter fetches, user-created grouping, user confirmation/rejection, and direct relationship operations.
3. Implement conservative candidate generation in a `DocumentIntelligence.Relationships` module: confirmed links first, exact reference numbers, then issuer/subject/period compatibility. It produces suggestions only and records rationale/evidence excerpt IDs.
4. Add `/matters` and `/matters/:id` inside the existing authenticated live session. The matter show page renders a timeline of linked documents, their role/period, and suggestion state.
5. Add document-page actions to create/link a matter, confirm/reject suggestions, and manually connect documents. Keep all destructive/corrective controls outside stream-item click traps; use conventional links/buttons with unambiguous events.
6. Integrate a confirmed duplicate relation with the duplicate-invoice feature only after its branch is on the base. Do not create a second fuzzy duplicate algorithm.

**Verify:**

- context tests prove user scoping for all matter/relationship operations;
- relationship self-links and contradictory confirmed/rejected state are rejected by database/schema constraints;
- LiveView tests cover confirm, reject, manual link, unlink, and inaccessible IDs;
- the tax fixture displays 2025 reconciliation and 2026 provisional documents as different roles/periods.

## Phase 4 — Cited document brief

**Goal:** Generate and display a fixed explanation for a single document.

1. Generate `document_briefs` migration/schema and add an orchestration context, for example `DocumentIntelligence.Briefs`.
2. Implement bounded candidate retrieval using only scoped evidence: confirmed matter/relationship links, exact identifiers, structured matches, then FTS excerpts. Return a typed evidence pack with documented candidate/excerpt/token limits.
3. Add an `:explainer` LLM role and `explain-document` prompt. Pass the evidence pack, not direct DB access and not whole documents beyond selected excerpts.
4. Validate the structured brief contract and citation IDs against the retrieval snapshot before persistence. Invalid output creates a durable failed brief with safe user-facing wording.
5. Mark a brief stale when its effective interpretation, source text, relationship status, or matter membership changes; regenerate asynchronously/on demand according to the final worker strategy.
6. Add a **Draft explanation** card on `DocumentLive.Show`: summary, current obligation, relation section, explicit unknowns, and evidence links. Existing preview/download controller routes remain the only original-document delivery path.
7. Add an entry from the matter timeline to the selected document's brief. The first release does not include free-form chat.

**Verify:**

- every rendered material claim has a citation to a source excerpt owned by the current scope;
- invalid/missing citation IDs fail validation;
- a stale brief is not rendered as current;
- the Swiss-tax, missing-payment, missing-source, and cross-user fixtures pass;
- tests pin Langfuse disabled and use injected explainer responses.

## Phase 5 — Evaluation, observability, and rollout

**Goal:** Prove that the brief is grounded and useful before adding more flexible interaction.

1. Add the fixture corpus defined in `research.md` and make it the required regression suite for retrieval and brief behavior.
2. Trace the interpreter and explainer with Langfuse using prompt/version and result metadata. Record retrieval IDs and evaluation-friendly result status; do not record chain-of-thought.
3. Add a simple user feedback control such as “This explanation helped / did not help,” using the existing scoped feedback and Langfuse score pattern where appropriate.
4. Review retrieval/citation metrics and user correction rates after a real sample of documents.
5. Document the operational privacy/retention model and how to retry an interpretation/brief failure.

**Verify:** full relevant suite plus `mix precommit`; no unrelated formatting diff remains. Record exact test commands in the PR description and commit body.

## Phase 6 — Optional guided questions, then vector decision

**Goal:** Expand only after the evidence contract is proven.

1. Add fixed guided questions to a matter or document page if Phase 5 metrics are acceptable. They reuse the same retrieval/evidence contract and do not create arbitrary chat history yet.
2. Run a retrieval evaluation comparing structured+FTS baseline with a prototype semantic retrieval implementation only if the baseline misses documented relations.
3. If vectors win on relevant recall without degrading citation correctness, introduce `pgvector` with excerpt-level embeddings, user-scoped filters, deletion/re-index semantics, and backup documentation.
4. Free-form chat remains a separately approved product phase after guided questions and adversarial tests succeed.

## Proposed PR structure

The implementation should be a focused stack, not one large change:

1. `feat/document-evidence-foundation` — source OCR text, excerpts, FTS, scoped evidence context.
2. `feat/document-interpretations` — structured interpreter, user corrections, document detail UI.
3. `feat/document-matters` — matter/relationship models, suggestions, timeline UI.
4. `feat/document-briefs` — bounded retrieval, explainer, cited brief UI/evaluation suite.
5. `feat/document-brief-feedback` — observability/feedback and post-rollout hardening if it cannot fit cleanly in #4.

Each child must be based on the current intended parent, use `gh stack` only if all parent worktrees permit it, and be rebased rather than merged with `origin/main` when the base advances.
