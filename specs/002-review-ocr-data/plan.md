# Implementation Plan: Review OCR/LLM Processed Data

**Branch**: `002-review-ocr-data` | **Date**: 2026-03-18 | **Spec**: [specs/002-review-ocr-data/spec.md](specs/002-review-ocr-data/spec.md)
**Input**: Feature specification from `/specs/002-review-ocr-data/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

Create a review interface for OCR/LLM processed invoice data that allows users to view, approve, reject, or amend extracted invoice information. The system automatically creates review records when OCR processing completes and maintains data integrity throughout the review process.

## Technical Context

**Language/Version**: Elixir 1.19 (existing Phoenix framework)
**Primary Dependencies**: Phoenix 1.8, Ecto, PostgreSQL, Req (HTTP client)
**Storage**: PostgreSQL (existing extracted_content table + new review_decisions and event_logs tables)
**Testing**: ExUnit (Elixir's built-in test framework)
**Target Platform**: Web application (Phoenix LiveView)
**Project Type**: Web application feature extension
**Performance Goals**: <2s page load time, handle 100 concurrent users
**Constraints**: Must remain decoupled from existing OCR/LLM pipeline, maintain data integrity
**Scale/Scope**: Handle 1000+ invoices in review queue efficiently

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [x] Follows existing Phoenix framework conventions
- [x] Uses existing authentication system
- [x] Maintains decoupled architecture
- [x] Uses Req library for HTTP requests (as per project guidelines)
- [x] Follows Tailwind CSS guidelines for UI
- [x] No implementation details in specification

## Project Structure

### Documentation (this feature)

```text
specs/002-review-ocr-data/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/
│   └── events.md        # Event contracts
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
# Contexts
lib/zaimu_tomo/
├── review.ex                    # Review context with business logic
├── review/
│   ├── review_decision.ex      # ReviewDecision schema
│   ├── event_log.ex            # EventLog schema
│   └── event_consumer.ex       # Event consumer for document processing events

# Document Processing (existing, modified)
lib/zaimu_tomo/document_processing/
├── ocr_worker.ex              # Modified to create ReviewDecision records
├── extracted_content/
│   ├── extracted_content.ex    # Modified: added user_id field
│   └── extracted_content_context.ex  # Modified: added get_by_id/1

# Web Layer
lib/zaimu_tomo_web/
├── router.ex                   # Modified: added /reviews routes
└── live/
    └── review_live/
        ├── index.ex            # Review list LiveView
        ├── show.ex             # Individual review display LiveView
        └── edit.ex             # Review edit form LiveView

# Migrations
priv/repo/migrations/
├── 20260319050855_create_review_decisions.exs
├── 20260319050858_create_event_logs.exs
└── 20260319050900_add_user_id_to_extracted_content.exs

# Tests
test/zaimu_tomo/
├── review_test.exs             # Review context tests
├── document_processing/
│   └── worker_test.exs         # OCR worker tests (new)
└── review/
    ├── review_decision_test.exs
    └── event_consumer_test.exs

test/zaimu_tomo_web/
└── live/
    └── review_live/
        ├── index_test.exs
        ├── show_test.exs
        └── edit_test.exs
```

**Structure Decision**: Following existing Phoenix framework conventions with:
- Context modules for business logic (Review)
- Schemas in nested modules (Review.ReviewDecision, Review.EventLog)
- LiveView for interactive UI components
- Proper separation between web layer and business logic
- All routes under `/reviews` in the `:require_authenticated_user` live_session

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No constitution violations detected. All requirements align with existing project guidelines and architecture.

## Implementation Notes

### Direct Creation Pattern
The implementation uses a **direct creation pattern** where the OCR worker (`ZaimuTomo.DocumentProcessing.Worker`) directly creates ReviewDecision records immediately after ExtractedContent creation. This approach was chosen for:

1. **Reliability**: Ensures ReviewDecision is always created when OCR completes
2. **Simplicity**: No need for separate event consumer process for critical path
3. **Atomicity**: ReviewDecision creation happens in the same process as OCR completion
4. **Decoupling**: The Review context still maintains its own logic and schemas

The EventConsumer (`ZaimuTomo.Review.EventConsumer`) is still implemented and started in the supervision tree for future event-driven enhancements and for consuming `invoice_review:completed` events.

### Form Handling for Nested Maps
The edit form uses **standalone inputs with `name` attributes** for nested `decision_data` map fields because Ecto FormField doesn't support nested atom access for map types. The pattern is:
- Inputs use `name="decision_data[field_name]"` format
- `handle_event` extracts these using custom `extract_nested_params/2` function
- Initial values pre-populated from `original_data` in mount
