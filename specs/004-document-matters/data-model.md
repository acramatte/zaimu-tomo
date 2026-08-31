# Data Model: Document Matters and Evidence-Grounded Briefs

**Status**: Proposed design. Tables and field names are intentionally explicit so an implementing agent can create migrations with Phoenix/Ecto generators and preserve scope boundaries.

## 1. Existing source-of-truth chain

```text
Document
  -> ExtractedContent (machine invoice facts)
  -> ReviewDecision (human-reviewed facts)
  -> JournalEntry (immutable accounting record after posting)
  -> TaxDeductionClaim (human-owned tax lifecycle)
```

The feature adds interpretation and explanatory evidence alongside this chain. It does not move, rewrite, or derive accounting authority from the new data.

## 2. New entities

### 2.1 `document_texts`

App-owned OCR evidence produced from a successful extraction.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `document_id` | FK `documents` | `null: false`, `on_delete: :delete_all`, unique: one active OCR body per extraction version design below |
| `extracted_content_id` | FK `extracted_content` | `null: false`, `on_delete: :delete_all`, unique |
| `user_id` | FK `users` | `null: false`, scope filter copied from document/extraction |
| `body` | `:text` | `null: false`, original OCR markdown; never created from LLM output |
| `checksum` | string | `null: false`, SHA-256 of normalized body for idempotency |
| `language` | string | nullable; optional future search hint |
| timestamps | UTC | standard |

Indexes:

- unique `[:extracted_content_id]`
- `[:user_id, :document_id]`
- GIN FTS index on the generated/current `search_vector` described below

**FTS implementation decision**: Use a migration-managed `tsvector` column populated from `body` and a GIN index. The trigger/generated-column exact syntax is an implementation choice, but it must be migration-owned, re-indexable, and tested with unaccented/lowercase query normalization. Do not try to query raw OCR markdown with `%ILIKE%` at archive scale.

### 2.2 `document_text_excerpts`

Stable, bounded excerpts used for citation and prompt construction.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `document_text_id` | FK `document_texts` | `null: false`, `on_delete: :delete_all` |
| `position` | integer | `null: false`, zero-based ordering |
| `start_offset`, `end_offset` | integer | `null: false`; source-text byte/character offsets with one documented convention |
| `body` | `:text` | `null: false`; exact excerpt copied from `document_texts.body` |
| `token_estimate` | integer | `null: false`; prompt budget accounting |
| timestamps | UTC | standard |

Constraints and indexes:

- unique `[:document_text_id, :position]`
- check `start_offset >= 0`, `end_offset > start_offset`, `token_estimate > 0`
- index `[:document_text_id, :position]`

The excerpt builder must be deterministic. A reprocessing run creates a new `document_text` through a new extraction; it must not mutate citations to an older source body.

### 2.3 `document_interpretations`

A versioned, structured reading of one document. Machine and user interpretations live as separate rows, so user correction does not overwrite machine output.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `document_id` | FK `documents` | `null: false`, `on_delete: :delete_all` |
| `document_text_id` | FK `document_texts` | nullable for user-only corrections; source for machine output |
| `user_id` | FK `users` | `null: false` |
| `source` | string | `null: false`, `machine` or `user` |
| `status` | string | `null: false`, `pending`, `ready`, `failed`, `superseded` |
| `document_role` | string | nullable until known; constrained vocabulary from spec |
| `issuer` | string | nullable |
| `subject_label` | string | nullable; person/entity named in document, not an application user foreign key |
| `reference_numbers` | `:map` | `null: false`, default empty array/map contract documented in schema |
| `periods` | `:map` | `null: false`, list of normalized period maps |
| `obligations` | `:map` | `null: false`, list of currency/amount/deadline/reference maps |
| `confidence` | decimal/float | nullable; only represents model confidence, never source truth |
| `error_details` | `:map` | nullable; durable processing failure details |
| `model_metadata` | `:map` | nullable; prompt/model version and source excerpt IDs, never hidden reasoning |
| timestamps | UTC | standard |

Indexes:

- `[:user_id, :document_id, :source, :inserted_at]`
- `[:user_id, :document_role]`
- GIN indexes only for JSON fields that concrete retrieval queries need; do not index every JSON key speculatively.

Effective interpretation rule:

1. a current user interpretation wins;
2. otherwise the latest successful machine interpretation wins;
3. otherwise the document has no usable interpretation.

The context returns the effective struct/map explicitly. Templates never choose `user || machine` inline.

### 2.4 `financial_matters`

A user-owned case file grouping related documents.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `user_id` | FK `users` | `null: false`, `on_delete: :delete_all` |
| `kind` | string | `null: false`, `tax`, `insurance`, `utility`, `supplier`, `other` |
| `title` | string | `null: false`, <= 300 chars |
| `subject_label` | string | nullable; scope-local person/entity label |
| `issuer` | string | nullable |
| `status` | string | `null: false`, `open`, `settled`, `archived` |
| timestamps | UTC | standard |

Indexes:

- `[:user_id, :status, :updated_at]`
- `[:user_id, :kind, :subject_label]`

`settled` is a user-controlled matter state; it must not be inferred from an invoice or used to mutate a payment/accounting record.

### 2.5 `matter_documents`

Links a source document to a matter and identifies its role in that matter.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `matter_id` | FK `financial_matters` | `null: false`, `on_delete: :delete_all` |
| `document_id` | FK `documents` | `null: false`, `on_delete: :delete_all` |
| `user_id` | FK `users` | `null: false` and must match the matter/document owner in context code |
| `role` | string | `null: false`, vocabulary from spec |
| `link_source` | string | `null: false`, `user` or `system_suggestion` |
| `confidence` | decimal/float | nullable for suggestions |
| `rationale` | string | nullable, <= 1,000 chars, user-visible |
| `confirmed_at` | UTC datetime | nullable; required for user-confirmed active link by changeset rule |
| `rejected_at` | UTC datetime | nullable; a rejected suggestion remains audit data but is excluded from active retrieval |
| timestamps | UTC | standard |

Constraints/indexes:

- unique `[:matter_id, :document_id]`
- index `[:user_id, :document_id]`
- index `[:matter_id, :confirmed_at]`
- check that `confirmed_at` and `rejected_at` are not both set

### 2.6 `document_relationships`

Direct, evidence-bearing document-to-document relationship.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `source_document_id` | FK `documents` | `null: false`, `on_delete: :delete_all` |
| `target_document_id` | FK `documents` | `null: false`, `on_delete: :delete_all` |
| `user_id` | FK `users` | `null: false` |
| `relationship_type` | string | `null: false`, constrained vocabulary from spec |
| `source` | string | `null: false`, `machine` or `user` |
| `status` | string | `null: false`, `suggested`, `confirmed`, `rejected`, `superseded` |
| `confidence` | decimal/float | nullable |
| `rationale` | string | nullable, <= 1,000 chars |
| `evidence` | `:map` | `null: false`; excerpt IDs plus small metadata, not copied OCR bodies |
| `confirmed_at` | UTC datetime | nullable |
| timestamps | UTC | standard |

Constraints/indexes:

- check `source_document_id <> target_document_id`
- unique `[:source_document_id, :target_document_id, :relationship_type, :source]`
- index `[:user_id, :source_document_id, :status]`
- index `[:user_id, :target_document_id, :status]`

A user rejection is retained and takes precedence over a matching machine suggestion in candidate generation. Direct relationships are directional even if the UI phrases an inverse form.

### 2.7 `document_briefs`

Persisted generated result and provenance for display, retry, audit, and failure status.

| Field | Type | Constraints / purpose |
|---|---|---|
| `id` | integer | primary key |
| `document_id` | FK `documents` | `null: false`, `on_delete: :delete_all` |
| `user_id` | FK `users` | `null: false` |
| `status` | string | `null: false`, `pending`, `ready`, `failed`, `stale` |
| `content` | `:map` | nullable structured brief contract; present only for `ready` |
| `retrieval_snapshot` | `:map` | `null: false`; candidate/excerpt/relationship IDs and version data |
| `model_metadata` | `:map` | nullable; role, model, prompt identity, duration/usage; no hidden reasoning |
| `error_details` | `:map` | nullable |
| `generated_at` | UTC datetime | nullable |
| timestamps | UTC | standard |

Indexes:

- unique `[:document_id]` for the current brief record; regeneration updates/replaces under explicit stale semantics
- `[:user_id, :status, :updated_at]`

A brief becomes `stale` when its source text, effective interpretation, confirmed/rejected relationship, or matter membership changes. The UI never displays a stale brief as current.

## 3. Cross-entity invariants

1. **Scope is structural.** Context queries join/filter `user_id` on the root and related entities. A matching foreign key alone is not authorization.
2. **Evidence is immutable in meaning.** Citations reference a particular `document_text_excerpts` row; regenerated text gets new rows through a new extraction version.
3. **Financial side effects are prohibited.** No new entity is an input to `Accounting.post_entry/6`, tax-claim state transitions, or payment execution.
4. **User judgment supersedes automation.** Effective interpretation and active links prefer user corrections/confirmations; machine data remains audit history.
5. **Deletions cannot create dangling citations.** Cascading source deletion removes derived text/links/briefs, or a context marks them stale before render. Tests must prove no orphan source ID is exposed.
6. **No arbitrary subject access.** `subject_label` is text attached to a user's archive; it is not an account/user lookup.

## 4. Relationship to in-flight work

- The duplicate-invoice-detection branch should map a reviewed duplicate decision to `document_relationships.relationship_type = "duplicate_of"` only after its domain rules land. Do not reimplement fuzzy duplicate matching in this feature.
- The tax-claim-lifecycle branch owns claim-state transitions. This feature may cite a tax claim as contextual evidence only after deciding how its branch is integrated; it cannot make an authority/lifecycle decision.
- Before implementation, rebase this work on the current `origin/main` and inspect which of those branches have merged. Do not couple migrations to an unmerged schema without an explicit stacked-PR decision.
