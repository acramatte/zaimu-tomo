# Research: Mistral OCR Document Annotation for the Interpretation Stage

**Date**: 2026-09-29
**Method**: Mistral's public docs, model cards, and OpenAPI spec (`https://docs.mistral.ai/openapi.yaml`), all read on 2026-09-29, plus a read-only look at `origin/main`. **No Mistral API calls were made, and no API keys were read.** Anything marked *unverified* must be confirmed by the spike in `plan.md` §5.

## 1. Mistral API facts (as documented)

| Topic | Fact | Source |
|---|---|---|
| Endpoint | `POST /v1/ocr`. Annotation is added with extra request parameters on the same endpoint. There is no separate call. | [A], [B] |
| Request fields | `document_annotation_format` (`ResponseFormat`; the OpenAPI description says *"Only json_schema is valid for this field"*). `document_annotation_prompt` (string; *"A document_annotation_format must be provided"*). `bbox_annotation_format` (per image, json_schema only). Also `pages` (0-based list or range string), `include_blocks`, `confidence_scores_granularity`, `table_format`, `extract_header`/`extract_footer`. | [B], [C] |
| Schema envelope | `ResponseFormat{type: "json_schema", json_schema: JsonSchema}` with `JsonSchema{name (required), description, schema (required, object), strict (default **false**)}`. We must send `strict: true` explicitly. | [C] |
| Schema features | The docs say schemas *"accept nested objects, arrays, enums"* and that field `description`s act as per-field extraction instructions. **No published list of unsupported JSON-Schema keywords was found** (*unverified*: `format`, `pattern`, `oneOf`, numeric bounds). | [A] |
| How it runs | *"We run OCR and send the output text in Markdown, along with the first eight extracted image bounding boxes, to a vision-capable LMM, together with the provided annotation format."* For OCR 4: *"the OCR output is fed to `mistral-small-2603`"*. That is a second model, run server-side after OCR. | [A], [D] |
| Response shape | `OCRResponse{pages[] (required), model (required), document_annotation: string \| null, usage_info (required)}`. `document_annotation` is a **JSON string** that has to be decoded. Note that the prose docs call it `dict\|null`; trust the OpenAPI type and decode defensively. `usage_info` has only `pages_processed` and `doc_size_bytes`, with **no token counts** for the annotation LLM. | [C], [E] |
| Limits | File ≤ 50 MB and ≤ 1,000 pages. *"Each annotation accepts a maximum of 8 image bounding boxes. We recommend using document annotation for text-focused documents."* Mistral's own cookbook: *"Document Annotations has a limit of 8 pages, we recommend splitting your documents"*. Haystack's integration docs repeat the 8-page limit and say oversized documents *"will not be processed for document annotation"* (*unverified* for OCR 4.1). | [A] FAQ, [F], [G] |
| Pricing | OCR 4.0 / 4.1: **$4 / 1000 pages**, **$5 / 1000 annotated pages**. OCR 3 (`mistral-ocr-2512`): $2 / $3. The Batch API gives 50% off. Mistral Small 4 chat: $0.15 per M input tokens, $0.6 per M output tokens. | [H], [I], [J], [K] |
| Latency | **Not published** for annotation. Structurally it adds one LLM generation after OCR on the critical path. It must be measured. | [A], [D] |
| Model pinning | The code on `main` uses the alias `mistral-ocr-latest` (`lib/zaimu_tomo/document_processing/document_ocr.ex`). `-latest` *"points to Latest General Availability version, across generations"*. Aliases *"may expose you to silent updates in model behavior and pricing. For precise control, pin … major.minor"*. GA models get no silent updates and six months' deprecation notice. The annotation LLM **cannot be selected or pinned** in the request, and it is **not reported** in the response. The `model` field is the OCR model. | [B], [C], [L] |
| Block/confidence data | OCR 4+ can return paragraph-level `blocks` and page/block/word confidence scores. These are useful as verifier evidence later but out of scope here. | [B] |

Sources:

- [A] Document Annotations — https://docs.mistral.ai/studio/document-processing/annotations (including FAQ)
- [B] OCR Processor — https://docs.mistral.ai/studio/document-processing/basic_ocr
- [C] OpenAPI — https://docs.mistral.ai/openapi.yaml (`OCRRequest`, `OCRResponse`, `ResponseFormat`, `JsonSchema`, `OCRUsageInfo`) and https://docs.mistral.ai/api/endpoint/ocr
- [D] "Introducing OCR 4" — https://mistral.ai/news/ocr-4/
- [E] OCR API reference example response — https://docs.mistral.ai/api/endpoint/ocr
- [F] Cookbook "Extract Data from Documents via Annotations" — https://docs.mistral.ai/resources/cookbooks/mistral-ocr-data_extraction
- [G] Haystack Mistral integration — https://docs.haystack.deepset.ai/reference/integrations-mistral
- [H] OCR 4.1 model card — https://docs.mistral.ai/models/ocr-4-1
- [I] OCR 4.0 model card — https://docs.mistral.ai/models/ocr-4-0
- [J] OCR 3 model card — https://docs.mistral.ai/models/ocr-3-25-12
- [K] Pricing — https://docs.mistral.ai/inference/pricing
- [L] Model lifecycle policy — https://docs.mistral.ai/inference/model-lifecycle

## 2. Cost and latency

These figures are order-of-magnitude estimates from list prices. They are not measurements.

| Per document | Pages | Plain OCR 4.x | + annotation | Δ annotation | Direct interpreter call on markdown (Mistral Small 4, ~3k in / 0.5k out tokens) |
|---|---|---|---|---|---|
| Letter | 1 | $0.004 | $0.005 | +$0.001 | ≈ $0.00075 |
| Assessment | 3 | $0.012 | $0.015 | +$0.003 | ≈ $0.001 |
| Long invoice | 8 | $0.032 | $0.040 | +$0.008 | ≈ $0.002 |

Conclusions:

- **Annotation costs more in dollars than a direct small-model call** for every document length, because it is billed per page. At personal-archive volumes (hundreds of documents a year) both amounts are negligible. **Cost is not a deciding factor either way.**
- **The interpreter role on FLM/Ollama has no marginal dollar cost** but takes local NPU time. The current extractor and verifier default to FLM (`config/config.exs`).
- **The possible real benefit is latency.** Annotation saves one client round trip and does not queue behind the local NPU. It also sees up to 8 images, which a markdown-only interpreter cannot. None of this is proven. The spike measures it.

## 3. Failure modes and required handling

| # | Failure | Detection | Handling |
|---|---|---|---|
| F1 | `document_annotation` is `null` although requested | nil check | `annotation_status: absent`. Next configured producer runs, or `failed`. |
| F2 | Document over 8 pages | page count from `usage_info.pages_processed` / `pages` | *Unverified*: the annotation may be null, truncated, or the request rejected. The spike determines which. The design handles all three (spec US3.3). |
| F3 | String is not valid JSON | `Jason.decode/1` error | `annotation_status: invalid_json`. Raw string kept in `ocr_metadata`. |
| F4 | Valid JSON, but wrong enum, bad date, or bad currency | `Interpretation.changeset/1` / `ExtractedData.changeset/1` | `annotation_status: invalid_domain`, errors recorded. JSON-schema mode constrains shape, not truth. |
| F5 | Schema-valid but factually wrong (hallucinated amount or role) | Verifier, TypeSafe, human review, corpus metrics | Same as any producer: independent verifier, review UI. |
| F6 | Mistral rejects our schema (400) | HTTP status on the OCR call | Deterministic, so caught by contract test plus spike. **Risk:** in production this fails the whole OCR request, and OCR text is lost along with the annotation. Mitigation: an explicit schema-rejection error class, retry once *without* annotation, record it. |
| F7 | Transient 429/5xx on the combined call | HTTP status | Oban retry of the OCR stage only. The interpretation stage has not run yet. |
| F8 | The annotation LLM changes under us (provider-controlled) | Not visible in the response | Pin the OCR model. Record `response.model`, `schema_version`, and prompt version. Re-run the corpus when Mistral announces Document AI changes. |
| F9 | Prompt injection in document text | Changeset plus bounded enum fields | Same as the interpreter role. The output is data, never instructions. |

## 4. Architecture decisions

| ID | Decision | Rationale |
|---|---|---|
| R1 | **One `Interpretation` contract** (embedded Ecto schema plus changeset) with two producers: `:ocr_annotation` and `:interpreter`. The JSON Schema sent to Mistral and the ReqLLM schema used by the interpreter are **both generated from this module**. | The contract has one source of truth. Schema drift between producers becomes impossible by construction. |
| R2 | Producers are an **ordered, explicit config list** per stage (`interpretation: [enabled: false, producers: [:ocr_annotation, :interpreter]]`). | Fallback is configured and recorded, never implicit (user rule). |
| R3 | The OCR stage persists `document_texts.body` plus `ocr_metadata` (`provider`, `model`, `pages_processed`, `annotation_requested`, `raw_annotation` string, `schema_version`, `prompt_version`) **before** any decoding. | Evidence-first (#61 D3). A retried interpretation never re-runs OCR. |
| R4 | The annotation schema has two top-level keys: `interpretation` (the contract) and `invoice_candidate` (all fields nullable, mirroring `ExtractedData`). The candidate goes **only** to the extraction stage as a producer input, and it is validated by the unchanged `ExtractedData.changeset/1`. | Keeps option (c): the invoice schema's required fields never apply to non-invoices, and interpretation stays invoice-agnostic. Per-page pricing makes the extra fields free at the margin. |
| R5 | Invoice facts from annotation start in **shadow** mode: the extractor still runs, and the candidate is compared and recorded. Promotion to the primary producer is gated on the corpus (spec SC2). | The extractor has production history, and annotation does not. |
| R6 | The **verifier remains mandatory and separate** whenever facts exist, whatever the producer. When the producer is `:ocr_annotation`, the verifier must not be a Mistral Small model (startup config check). | Independence: the judge must not be the author. The verifier sees only markdown. This checks grounding against the OCR text, not against pixels. OCR errors hit both sides alike, so TypeSafe (a different vendor) is the most independent check. |
| R7 | TypeSafe input is unchanged (`markdown`, `extracted_data`, `currency_hint`). The producer is added to the shadow record's metadata. | No TypeSafe contract change. Evaluation can split outcomes by producer. |
| R8 | Pin the OCR model to a fixed `major-minor` id (candidate: OCR 4.1; the exact id is confirmed through `/v1/models` in the spike) instead of `mistral-ocr-latest`. | The annotation model follows the OCR generation. An alias would move both silently. |
| R9 | Annotation is traced as its own Langfuse generation `ocr-document-annotation`. Input: `document_annotation_prompt`, schema, schema version, markdown. Output: the raw annotation string. Usage: `pages_processed`. The annotation prompt is managed like the others (`Langfuse.fetch_prompt/2`, with a local fallback). | The user wants full prompts and responses in Langfuse. `Langfuse.trace_llm_generation/4` records ReqLLM responses today, so it needs a small OCR-response output encoder. |

## 5. Rejected alternatives

- **Annotation-only interpretation (no interpreter role).** This fails for documents over 8 pages, null annotations, and any non-Mistral configuration. The result would be a hole, or a Mistral-only path.
- **A separate parallel interpreter call beside the existing extractor.** The user rejected this as a legacy-code risk: two independent judgments of role with no gate.
- **Widening the invoice extractor to all documents.** The user rejected this because non-invoices fail the required `ExtractedData` fields.
- **Using annotation as the verifier, or trusting self-reported confidence.** Both violate R6.

## 6. Privacy and lock-in

- **Privacy:** the document already goes to Mistral for OCR, and annotation runs inside the same vendor and endpoint. No new processor is added. Langfuse already receives prompts that contain OCR markdown under its existing configuration. That now includes the annotation input and output. This matches the user's preference, but the Langfuse retention settings should be re-checked.
- **Lock-in:** the Mistral-specific code is limited to one request-builder option plus one decoder, behind the producer interface. Turning it off takes one config change and costs no functionality, because the interpreter covers everything. This bounded, reversible coupling is acceptable.
