# Implementation Plan: Persist Extracted OCR/LLM Content

**Branch**: `001-persist-ocr-data` | **Date**: 2026-03-16 | **Spec**: [link]
**Input**: Feature specification from `/specs/001-persist-ocr-data/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

This plan implements persistent storage for extracted OCR/LLM content to address the current system's limitation of losing valuable extracted data after processing. The solution will store extracted content in the existing PostgreSQL database, associate it with original documents, and provide retrieval and filtering capabilities.

## Technical Context

**Language/Version**: Elixir 1.15 (as specified in mix.exs)   
**Primary Dependencies**: Ecto, Postgrex, Phoenix Framework   
**Storage**: PostgreSQL (existing database infrastructure)   
**Testing**: ExUnit (Elixir's built-in test framework)   
**Target Platform**: Linux server (Phoenix web application)   
**Project Type**: Web service (Phoenix application)   
**Performance Goals**: Retrieve extracted content in under 500ms for 95% of requests, handle 10,000+ records without degradation   
**Constraints**: Maintain 99.9% storage success rate, prevent orphaned entries, ensure data consistency   
**Scale/Scope**: Support 10,000+ extracted content records, handle up to 100 concurrent extraction requests

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

[Gates determined based on constitution file]

## Project Structure

### Documentation (this feature)

```text
specs/001-persist-ocr-data/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
# Web application structure (Phoenix framework)
lib/
├── zaimu_tomo/
│   ├── document_processing/
│   │   ├── extracted_content.ex      # New: ExtractedContent context
│   │   ├── extracted_content/        # New: ExtractedContent schema and changeset
│   │   └── ... (existing OCR modules)
│   └── ... (other contexts)

priv/
└── repo/
    └── migrations/
        └── *create_extracted_content_table.exs  # New migration

test/
└── zaimu_tomo/
    └── document_processing/
        └── extracted_content_test.exs  # New tests
```

**Structure Decision**: Using the existing Phoenix web application structure with new context/module for extracted content management. This follows Phoenix best practices for organizing business logic by domain.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| None identified | All requirements align with existing architecture | N/A |

## Phase 0: Research

### Research Questions

1. **Storage Strategy**: What's the optimal database schema for storing extracted content with document associations?
   - Decision: Create a dedicated `extracted_content` table with foreign key to documents table
   - Rationale: Maintains data integrity, enables efficient queries, follows relational database best practices
   - Alternatives: JSON field in documents table (less query flexibility), separate database (unnecessary complexity)

2. **Duplicate Handling**: How should the system handle duplicate document processing?
   - Decision: Create new extraction entries for each processing run
   - Rationale: Preserves historical data, allows comparison between runs, matches stakeholder requirement
   - Alternatives: Overwrite existing entries (loses history), skip processing (loses new data)

3. **Error Handling**: What error information should be stored for failed extractions?
   - Decision: Store error type, message, stack trace, and timestamp
   - Rationale: Provides sufficient debugging information while maintaining reasonable storage
   - Alternatives: Full error dump (too verbose), minimal error code (insufficient for debugging)

4. **Content Size Limits**: What's the appropriate maximum size for extracted content?
   - Decision: 10MB per document
   - Rationale: Balances support for large documents with storage efficiency, matches stakeholder input
   - Alternatives: Unlimited (risk of storage abuse), 1MB (too restrictive)

5. **Data Retention**: What retention period should apply to extracted content?
   - Decision: 5 years
   - Rationale: Supports medium-term trend analysis while managing storage, matches stakeholder requirement
   - Alternatives: Permanent (unbounded storage growth), 1 year (too short for analysis)

6. **Search Implementation**: How to implement full-text search for extracted content?
   - Decision: Use PostgreSQL's built-in full-text search capabilities
   - Rationale: Leverages existing database infrastructure, provides good performance for our scale
   - Alternatives: External search engine (Elasticsearch) would add complexity, dedicated search service would require additional infrastructure

### Best Practices Research

1. **Ecto Schema Design**: Research best practices for Ecto schemas with JSON fields
   - Finding: Use `:map` type for structured JSON, `:string` for raw JSON strings
   - Application: Use `:map` for `ocr_content` and `llm_content` fields

2. **Phoenix Context Organization**: Research Phoenix context patterns for new domains
   - Finding: Create separate context module for extracted content management
   - Application: New `ExtractedContent` context following Phoenix conventions

3. **Database Indexing**: Research indexing strategies for query performance
   - Finding: Index foreign keys and frequently queried fields
   - Application: Index `document_id`, `status`, and `extraction_timestamp`

4. **Error Recovery**: Research patterns for failed extraction retry
   - Finding: Implement exponential backoff with maximum retry limit
   - Application: Add retry mechanism with 3 attempts and increasing delays

5. **Event Consistency**: Research event emission patterns with persistence
   - Finding: Emit events only after successful database transactions
   - Application: Wrap event emission in Ecto transaction callbacks

## Phase 1: Design

### Data Model

**ExtractedContent Schema:**
```elixir
schema "extracted_content" do
  field :ocr_content, :map
  field :llm_content, :map
  field :confidence_score, :float
  field :status, :string
  field :error_details, :map
  field :ocr_version, :string
  field :llm_version, :string
  field :processing_duration_ms, :integer
  field :extraction_timestamp, :naive_datetime
  
  belongs_to :document, ZaimuTomo.Documents.Document
  
  timestamps()
end
```

**Validation Rules:**
- `status`: Must be one of ["success", "partial", "failed"]
- `confidence_score`: Must be between 0.0 and 1.0
- `document_id`: Must exist in documents table
- `ocr_content` and `llm_content`: Maximum size 10MB when serialized

**State Transitions:**
- Created → Processing → Success/Partial/Failed
- Failed → Retry (max 3 attempts) → Success/Failed

### Interface Contracts

**API Endpoints:**

1. **GET /api/extracted_content/:document_id**
   - Request: Document ID in path
   - Response: Extracted content with metadata
   - Status Codes: 200 (success), 404 (not found), 500 (error)

2. **GET /api/extracted_content**
   - Request: Optional filters (status, date_range, min_confidence, limit, offset)
   - Response: Paginated list of extracted content
   - Status Codes: 200 (success), 400 (invalid filters), 500 (error)

3. **GET /api/extracted_content/:document_id/latest**
   - Request: Document ID in path
   - Response: Most recent extracted content for document
   - Status Codes: 200 (success), 404 (not found), 500 (error)

4. **POST /api/extracted_content/:id/retry**
   - Request: Extraction ID in path
   - Response: Retry status
   - Status Codes: 202 (accepted), 404 (not found), 409 (not retryable), 500 (error)

**Event Contracts:**

1. **document_processing:success**
   - Payload: `{document_id, extraction_id, timestamp, status: "success"}`
   - Emitted: After successful persistence

2. **document_processing:failed**
   - Payload: `{document_id, extraction_id, timestamp, status: "failed", error_details}`
   - Emitted: After failed persistence attempts

### Quickstart Guide

**Setup:**
1. Run migration: `mix ecto.migrate`
2. Add to router: `resources "/extracted_content", ExtractedContentController`

**Basic Usage:**
```elixir
# Store extracted content
%{document_id: doc_id, ocr_content: raw_text, llm_content: structured_data} 
|> ExtractedContent.create_extracted_content()

# Retrieve by document
ExtractedContent.get_by_document(doc_id)

# Query with filters
ExtractedContent.list_extracted_content(status: "success", limit: 50)
```

**Testing:**
```elixir
# Run tests
mix test test/zaimu_tomo/document_processing/extracted_content_test.exs
```

## Phase 2: Implementation Tasks

*Tasks will be generated by `/speckit.tasks` command*

## Phase 3: Verification

*Verification plan will be created during task implementation*

## Open Questions

None - All critical decisions resolved in Phase 0 research

## Constitution Check (Post-Design)

*Re-evaluate gates after Phase 1 design completion*

[Updated constitution compliance status]

## Agent Context Update

*Will be performed by `/speckit.plan` command execution*

New technologies identified: None (using existing Elixir/Phoenix/Ecto stack)
