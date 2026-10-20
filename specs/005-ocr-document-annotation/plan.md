# Implementation Plan: Interpreter-First Pipeline with Optional Mistral Document Annotation

**Input**: `spec.md`, `research.md`, and PR #61 (`specs/004-document-matters`)
**Status**: Proposed. No production code in this PR.
**Base**: every implementation PR starts from a fresh worktree on explicit `origin/main`, after the Oban stack and #61's evidence foundation (Phase 1 of #61) have landed or been stacked deliberately.

## 1. The `Interpretation` contract

Proposed module `ZaimuTomo.DocumentIntelligence.Interpretation`: an embedded schema whose changeset is the only validation boundary for both producers.

```text
document_role     enum(tax_assessment, provisional_tax_bill, reconciliation, reminder,
                       credit_note, payment_confirmation, invoice, correspondence, other)  required
issuer            string | nil
subject_label     string | nil
language          string | nil        (ISO 639-1)
reference_numbers [%{kind: enum(invoice, assessment, customer, qr_reference, other), value: string}]
periods           [%{kind: enum(tax_year, service, billing, other), start_date: date|nil,
                     end_date: date|nil, label: string|nil}]
obligations       [%{kind: enum(payment_due, refund, instalment, none), amount_cents: int|nil,
                     currency: ISO 4217|nil, due_date: date|nil, reference: string|nil}]
```

- `json_schema/0` and `req_llm_schema/0` are **generated from the same field list**. The Mistral schema uses `strict: true`, marks every property required, and expresses nullability as a `["string","null"]` type union. That encoding is a *candidate*, and the spike confirms Mistral accepts it.
- `Interpretation.changeset/1` reuses `ZaimuTomo.Currency` normalization, the same way `ExtractedData.changeset/1` does.
- This refines `document_interpretations` in #61 as follows:
  - the fields above map one-to-one onto its columns;
  - #61's `model_metadata` gains `producer`, `annotation_status`, `schema_version`, and `prompt_version`;
  - #61's `document_texts` gains `ocr_metadata` (`research.md` R3).

  If #61 merges first, these land as a follow-up migration. Otherwise the change is folded into #61 on the user's instruction.

The annotation request schema is `{interpretation: <Interpretation>, invoice_candidate: <ExtractedData fields, all nullable> | null}`.

## 2. Configuration

Every new stage is disabled by default and has no implicit fallback.

```elixir
config :zaimu_tomo, :ocr,
  model: "mistral-ocr-4-1",             # pinned; exact id confirmed in the spike
  document_annotation: [enabled: false]  # adds document_annotation_format to /v1/ocr

config :zaimu_tomo, :ai_workflow,
  interpreter: [enabled: false, backend: :flm, model: "..."],
  extractor:   [backend: :flm, model: "gemma4-it:e4b"],
  verifier:    [backend: :flm, model: "phi4-mini-it:4b", max_tokens: 4096]

config :zaimu_tomo, :pipeline,
  interpretation: [enabled: false, producers: [:ocr_annotation, :interpreter]],
  invoice_extraction: [producers: [:extractor]]   # [:ocr_annotation, :extractor] only after SC2
```

Validation happens at boot (`config/runtime.exs`), and the leaf client does no defaulting:

- listing `:ocr_annotation` as a producer requires `ocr.document_annotation.enabled`;
- listing `:interpreter` requires `ai_workflow.interpreter.enabled`;
- the verifier backend and model must differ from the annotation model family when `:ocr_annotation` is an invoice producer (R6).

## 3. Stage contracts (job-based, dispatcher-agnostic)

| Stage | Command | Writes | Deletes/replaces |
|---|---|---|---|
| OCR | `%{document_id, currency_hint}` | `document_texts` (body, `ocr_metadata`) | the OCR step inside `Worker.process/1` |
| Interpretation | `%{document_id, document_text_id}` | `document_interpretations` row (`ready`, `failed`, `disabled`) | n/a (new) |
| Invoice extraction | `%{document_id, document_text_id, interpretation_id \| nil, currency_hint}` | `extracted_content` (`success`, `failed`, `not_applicable`) + `Review.create_initial_decision/1` | the extractor/verifier `with` chain in `Worker.process/1` |
| Verification | inside the extraction stage, as today (`LLMClient.verify_extraction/2`), then `TypeSafeVerification.enqueue/1` | `analysis["verification"]`, TypeSafe shadow | n/a |

The extraction gate is a single predicate, `effective_role == "invoice" or interpretation.status == "disabled"`, and it has a unit test. The `disabled` branch keeps today's behaviour for users who have not enabled interpretation. It is the same code path, not a second one.

## 4. Phases, and exactly what each one deletes

### Phase 0 — Spike (user-approved and user-run; nothing merged)

See §5. It produces a decision record appended to `research.md`.

**Deletes:** the spike script is removed in the same PR that records the decision. It never enters `lib/`.

### Phase 1 — Evidence + contract + interpreter role (`feat/interpreter-first-pipeline`)

1. `Interpretation` contract, including schema generators and tests.
2. `LLMClient` gains an `:interpreter` role and `interpret_document/1` (Langfuse prompt `interpret-document` with a local fallback), parsed through `Interpretation.changeset/1`.
3. Split `Worker.process/1` into the stage functions in §3, wired to the Oban jobs from the durable-processing stack.
4. Add extraction status `not_applicable` and the gate predicate. Non-invoice documents get **no** review decision (see open question Q2).

**Deletes in the same PR:**

- the inline `DocumentOCR.process → extract_invoice → verify_extraction` `with` chain in `Worker.process/1`;
- the `markdown` bundling in `persist_and_emit_success/6`'s `typesafe_input`, because the stage reads markdown from `document_texts`;
- storing the raw OCR body under `extracted_content.raw_llm_response` on success, because it moves to `document_texts.ocr_metadata`. The column stays for existing rows until a separate rename/cleanup migration.

After Phase 1 there is **one** pipeline. No extractor-first path remains.

### Phase 2 — Annotation producer for interpretation (`feat/ocr-document-annotation`)

1. `DocumentOCR` accepts `annotation: %{format: map, prompt: String.t()}` and adds `document_annotation_format` and `document_annotation_prompt` to the payload. It returns `raw_annotation` untouched.
2. `Interpretation.Producers.OCRAnnotation.decode/1`: nil check, then `Jason.decode`, then `Interpretation.changeset/1`, mapping each failure to an `annotation_status`.
3. Pin the OCR model (R8). Add the Langfuse `ocr-document-annotation` generation (R9).
4. Contract test: the same fixture JSON goes through both producer decoders and must yield identical `%Interpretation{}` structs.

**Deletes:** the hard-coded `@model "mistral-ocr-latest"` in `document_ocr.ex`, replaced by config.

### Phase 3 — Invoice candidate in shadow

1. The OCR request asks for `invoice_candidate` as well. The extraction stage still runs `:extractor`, validates the candidate with `ExtractedData.changeset/1`, and writes `analysis["annotation_candidate_comparison"]` (field-by-field equality).

**Deletes when the SC2 decision is made:** the comparison writer, either way.

- **Promote:** set `invoice_extraction.producers: [:ocr_annotation, :extractor]`. The extractor stays as the markdown fallback for documents over 8 pages, invalid annotations, and non-Mistral setups, so it keeps running in production.
- **Reject:** remove `invoice_candidate` from the annotation schema.

### Phase 4 — Disagreement surfacing

A pure comparison of interpretation obligations with extracted facts writes `analysis["disagreements"]`, plus a review UI badge. It inherits the review LiveViews' existing route placement inside the authenticated `live_session :require_authenticated_user`, because review is per user.

## 5. Spike design (for the user to approve and run; the agent does not run it)

**Script:** `scripts/spikes/ocr_annotation_spike.exs`, run with `mix run`.

- It reads PDFs from a directory the user names, **outside the repo**, and writes JSONL results plus a Markdown report to a git-ignored output directory.
- It uses the app's existing `:mistral` config. The script never prints or logs keys, and Langfuse stays disabled for the run.

**For each document:**

1. Plain `/v1/ocr` (pinned model) gives the latency baseline and the markdown.
2. `/v1/ocr` with the annotation schema and prompt gives the latency, the raw annotation, and the decode/changeset result.
3. The current `LLMClient.extract_invoice/2` on the markdown from call 1.
4. A prototype interpreter prompt on the same markdown, run on the configured backend (FLM, and optionally Mistral Small 4).
5. Everything is compared with a hand-labelled `expected.json` (role, issuer, periods, references, invoice fields).

**Corpus:** 25–40 real documents, labelled once by the user:

- Swiss final tax assessment, plus the prior-year reconciliation;
- provisional tax bill (instalments);
- reminder, credit note, payment confirmation;
- single-page invoice, and a multi-page invoice (≥ 9 pages, to exercise F2);
- scanned/low-quality image;
- French, Italian, and English documents (the rest German);
- one correspondence letter that contains prompt-injection-like text.

**Metrics:**

- role accuracy and **invoice recall** per producer;
- per-field exact match versus labels, for the annotation `invoice_candidate` and for the current extractor;
- annotation absent / invalid_json / invalid_domain rates;
- behaviour above 8 pages (F2);
- p50/p95 latency delta (call 2 − call 1) versus the interpreter call's latency;
- billed pages (`usage_info`) and a list-price cost estimate;
- schema keywords rejected (F6).

**Estimated cost:** under $1 at list price for 40 documents averaging 3 pages, with two OCR calls each.

**Decision rule:**

- Enable annotation for interpretation only if role accuracy ≥ the interpreter's, invoice recall is 100%, and p50 end-to-end latency improves by ≥ 20%.
- Promote the invoice candidate only if every field is ≥ the extractor.
- Otherwise keep the interpreter only and skip Phases 2–3 entirely.

## 6. Open questions for the user

1. **Q1 — Extraction scope.** Should `provisional_tax_bill` and `reminder` (both payable) also route to invoice extraction, or strictly `invoice` only, as decided so far?
2. **Q2 — Non-invoice review.** Should non-invoice documents get a review item at all, perhaps a lightweight "confirm role" review? Or only the interpretation panel from #61?
3. **Q3 — Disabled-interpretation gate.** Keep `interpretation disabled ⇒ extract unconditionally` (today's behaviour), or require interpretation before any extraction once Phase 1 ships?
4. **Q4 — Spike go-ahead.** Approve running the spike yourself, with the corpus location, and confirm that roughly $1 of Mistral spend is fine.
5. **Q5 — Verifier independence rule.** Is "the verifier must not be a Mistral Small model when annotation supplies invoice facts" strict enough, or should it be "the verifier must not be a Mistral model at all"?
6. **Q6 — Coordination with #61.** Fold the `ocr_metadata` and `model_metadata.producer` additions into #61's data model now, or keep them as this spec's follow-up migration?

## 7. Verification gates for implementation PRs (not run for this docs PR)

- `mix test test/zaimu_tomo/llm_client_test.exs test/zaimu_tomo/document_processing/` plus new contract tests;
- `mix precommit`;
- every test pins Langfuse disabled and injects OCR/LLM responses; no network access.
