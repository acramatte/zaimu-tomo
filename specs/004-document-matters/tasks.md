# Tasks: Document Matters and Evidence-Grounded Briefs

**Input**: Design documents in `specs/004-document-matters/`
**Prerequisites**: `spec.md`, `data-model.md`, `research.md`, `plan.md`
**Tests**: Required. Financial-document explanations need grounded retrieval, explicit source provenance, and ownership regression coverage.

## Format

`[ID] [P?] [Phase] Description`

- **[P]**: independent after named prerequisites; use separate files/worktrees when parallelizing.
- All code tasks must use the current branch's real module names and be rebased on the intended parent before implementation.

## Phase 0 — Baseline and integration

- [ ] T001 Inspect `origin/main` and in-flight duplicate/tax-claim branches; record whether any migration/context dependency is intentional before writing production code.
- [ ] T002 Create a dedicated implementation worktree from explicit `origin/main` and a feature branch; verify `git log origin/main..<branch>` is empty before edits.
- [ ] T003 [P] Read current tests for document processing, documents, review, document LiveViews, private preview/download, LLM client, and Langfuse; identify fixtures that must pin external configuration.
- [ ] T004 Add/centralize test setup that sets `:langfuse` to `enabled: false` and restores configuration on exit for all new AI-adjacent test modules.

## Phase 1 — Evidence foundation

- [ ] T005 Generate migration for `document_texts` and `document_text_excerpts`; implement FKs, check/unique constraints, ownership/indexes, and FTS GIN index from `data-model.md`.
- [ ] T006 Create `ZaimuTomo.DocumentEvidence.DocumentText` and `DocumentTextExcerpt` schemas with changesets in `lib/zaimu_tomo/document_evidence/`.
- [ ] T007 Create a scoped `ZaimuTomo.DocumentEvidence` context: persist source text, build/fetch excerpts, fetch scoped source by document, and full-text candidate queries. `Scope` is the first argument to public retrieval functions.
- [ ] T008 Implement deterministic excerpt segmentation with documented offset and size/token-estimation semantics; reject oversized/invalid excerpt shapes.
- [ ] T009 Update `lib/zaimu_tomo/document_processing/ocr_worker.ex` success orchestration to persist OCR markdown as app-owned evidence after its extraction record is created.
- [ ] T010 [P] Add `test/zaimu_tomo/document_evidence_test.exs` for source persistence, deterministic chunks, checksum/idempotency behavior, scoped fetches, and FTS.
- [ ] T011 [P] Extend `test/zaimu_tomo/document_processing/worker_test.exs` to prove successful OCR creates source evidence and failed OCR creates none.

## Phase 2 — Structured interpretation

- [ ] T012 Generate migration for `document_interpretations`, including source/status/role checks and indexes needed by concrete retrieval paths.
- [ ] T013 Create `ZaimuTomo.DocumentIntelligence.DocumentInterpretation` and changesets, including period/obligation embedded-map validation and machine/user source validation.
- [ ] T014 Create `ZaimuTomo.DocumentIntelligence` context with scoped effective interpretation lookup, machine persistence, user correction persistence, and explicit precedence rules.
- [ ] T015 Extend `lib/zaimu_tomo/llm_client.ex` with a dedicated configurable `:interpreter` role and a validated structured `interpret_document/1` contract. Do not add default/config fallback logic in the leaf client.
- [ ] T016 Extend `lib/zaimu_tomo/langfuse.ex` with local fallback prompt `interpret-document` plus production prompt retrieval variables/metadata.
- [ ] T017 Update successful worker orchestration to invoke the interpreter with the persisted source text and store a durable success/failure interpretation result.
- [ ] T018 Add a draft interpretation section and correction navigation/action to `lib/zaimu_tomo_web/live/document_live/show.ex`.
- [ ] T019 [P] Add `test/zaimu_tomo/document_intelligence_test.exs` covering schema validation, effective precedence, user correction audit preservation, and scope isolation.
- [ ] T020 [P] Extend `test/zaimu_tomo/llm_client_test.exs` and `test/zaimu_tomo/langfuse_test.exs` for interpreter role resolution and prompt compilation without network access.
- [ ] T021 [P] Extend `test/zaimu_tomo_web/live/document_live_test.exs` for draft/unverified rendering and user correction entry point.

## Phase 3 — Matters and relationships

- [ ] T022 Generate migrations for `financial_matters`, `matter_documents`, and `document_relationships` with constraints/indexes from `data-model.md`.
- [ ] T023 Create `FinancialMatter`, `MatterDocument`, and `DocumentRelationship` schemas under `lib/zaimu_tomo/matters/`.
- [ ] T024 Create a scoped `ZaimuTomo.Matters` context: list/fetch/create/update matters, link/unlink documents, create/confirm/reject relationships, and timeline retrieval.
- [ ] T025 Create `ZaimuTomo.DocumentIntelligence.Relationships` candidate generator: confirmed graph → exact references → issuer/subject/period compatibility; it writes suggestions only with evidence/rationale.
- [ ] T026 Add `live "/matters", MatterLive.Index, :index` and `live "/matters/:id", MatterLive.Show, :show` inside the existing authenticated router block.
- [ ] T027 Implement `MatterLive.Index` and `MatterLive.Show`, including confirmation/rejection/manual-link controls and a source-document timeline that labels inferred vs confirmed entries.
- [ ] T028 Add matter entry points to `DocumentLive.Show` without changing current preview/download route ordering.
- [ ] T029 Integrate confirmed duplicate decisions only after the duplicate-invoice implementation has merged and its public context contract is inspected; map it to an auditable `duplicate_of` relationship rather than duplicating detection.
- [ ] T030 [P] Add `test/zaimu_tomo/matters_test.exs` for all scope, relationship-state, link uniqueness, rejection-precedence, and deletion invariants.
- [ ] T031 [P] Add `test/zaimu_tomo_web/live/matter_live_test.exs` for list/show scope enforcement, timeline ordering, confirm/reject/manual link, and foreign-ID behavior.

## Phase 4 — Cited document brief

- [ ] T032 Generate migration for `document_briefs` with one current brief per document, status constraints, retrieval snapshot, and provenance fields.
- [ ] T033 Create `DocumentBrief` schema and a `ZaimuTomo.DocumentIntelligence.Briefs` context responsible for current/stale/failed state and regeneration rules.
- [ ] T034 Implement the bounded hybrid evidence-pack query: confirmed links/matter membership, exact references, structured matches, then FTS excerpts; enforce candidate, excerpt, byte, and estimated-token caps in code.
- [ ] T035 Extend `LLMClient` with the configurable `:explainer` role and structured `explain_document/1` contract; validate every citation against the evidence-pack IDs before accepting output.
- [ ] T036 Add `explain-document` local/Langfuse prompt and tracing metadata for retrieval snapshot/prompt/model identity. Do not persist chain-of-thought.
- [ ] T037 Invoke brief generation after successful interpretation/relationship refresh through a dedicated, observable orchestration boundary; persist durable failed state for source/LLM/schema errors.
- [ ] T038 Implement stale invalidation after source text, effective interpretation, matter membership, or confirmed/rejected relationship changes.
- [ ] T039 Render a cited **Draft explanation** card in `DocumentLive.Show`: summary, obligations, relationships, unknowns, and authenticated source-document links.
- [ ] T040 [P] Add `test/zaimu_tomo/document_intelligence/briefs_test.exs` for evidence-pack bounds, exact-match precedence, stale state, citation validation, and cross-user isolation.
- [ ] T041 [P] Add fixture-based brief contract tests for the Swiss tax, correction, duplicate, missing source, no payment proof, and prompt-injection scenarios from `research.md`.
- [ ] T042 [P] Extend `test/zaimu_tomo_web/live/document_live_test.exs` for citation rendering, stale/failed states, and document-preview links.

## Phase 5 — Evaluation and quality gates

- [ ] T043 Add a reusable test-support fixture corpus for document text, interpretation, matters, relationships, and expected cited brief assertions.
- [ ] T044 Add a scoped “helpful / not helpful” brief feedback action only after the brief UI is stable; reuse existing Langfuse score conventions but make disabled mode a no-op.
- [ ] T045 Document retry/recovery, prompt ownership, source-text retention, and no-side-effect guarantees in the relevant feature docs/README sections.
- [ ] T046 Run focused tests for each changed context/LiveView, then `mix compile --warnings-as-errors` and `mix precommit`; inspect and revert unrelated formatter churn before commit.
- [ ] T047 Before opening each implementation PR, inspect `git diff --check`, `git diff --stat origin/main...HEAD`, and PR scope; add a rationale-rich body with exact test commands and explicit non-goals.

## Deferred — Guided questions and vector retrieval

- [ ] T048 After production evaluation, add fixed guided questions that reuse the document brief evidence contract.
- [ ] T049 Design/run a measured FTS-vs-semantic retrieval evaluation before adding any vector extension or embedding dependency.
- [ ] T050 If approved by metrics, introduce `pgvector` with excerpt-level embeddings, scope filters, migration/backup/deletion semantics, and regression tests.
- [ ] T051 Obtain explicit product approval before adding free-form chat, conversation persistence, or cross-matter arbitrary questions.
