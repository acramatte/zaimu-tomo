# Feature Specification: Review OCR/LLM Processed Data

**Feature Branch**: `002-review-ocr-data`  
**Created**: 2026-03-18  
**Status**: Implemented  
**Input**: User description: "review of OCR/LLM processed/extracted data"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Processed Invoices (Priority: P1)

As a user, I want to see all invoices processed by OCR/LLM so I can review their accuracy before approval.

**Why this priority**: This is the core functionality needed to ensure data accuracy before financial operations.

**Independent Test**: Can be fully tested by loading the review page and verifying invoices are displayed with extracted data.

**Acceptance Scenarios**:

1. **Given** I am on the review page (`/reviews`), **When** I load the page, **Then** I see a list of all processed invoices for my account
2. **Given** invoices exist in the database, **When** I view the list, **Then** each invoice shows extracted data fields (invoice number, issuer, amount, date)
3. **Given** I have pending and completed reviews, **When** I view the list, **Then** pending reviews appear first, ordered by creation date

---

### User Story 2 - Approve or Reject Invoices (Priority: P2)

As a user, I want to approve, reject, or amend invoice data so I can ensure only accurate data is used for financial operations.

**Why this priority**: Critical for data quality control and financial accuracy.

**Independent Test**: Can be tested by performing approval/rejection actions and verifying the system responds appropriately.

**Acceptance Scenarios**:

1. **Given** I am viewing an invoice detail page (`/reviews/:id`), **When** I navigate there, **Then** I see all extracted data fields in a readable format
2. **Given** I am viewing an invoice, **When** I click "Edit" and update the review status to "approved", **Then** the invoice is marked as approved and saved
3. **Given** I am viewing an invoice, **When** I click "Edit" and update the review status to "rejected", **Then** the invoice is marked as rejected with my notes
4. **Given** I am viewing an invoice, **When** I click "Edit", modify fields (invoice_number, amount_to_pay_cents, etc.) and click "Save", **Then** the changes are saved to decision_data

---

### User Story 3 - Event Handling (Priority: P3)

As a system, I want to automatically create review records when OCR/LLM processing completes so users can immediately review new documents.

**Why this priority**: Ensures the review system stays in sync with OCR/LLM processing without manual intervention.

**Independent Test**: Can be tested by uploading a document, verifying OCR processing completes, and checking that a review record is automatically created.

**Acceptance Scenarios**:

1. **Given** a document is successfully processed by OCR/LLM, **When** the OCR worker completes, **Then** a new ReviewDecision record is automatically created with `review_status: "pending"`
2. **Given** a document processing fails, **When** the OCR worker completes, **Then** a new ReviewDecision record is automatically created with `review_status: "failed"`
3. **Given** a ReviewDecision is created, updated, or completed, **When** the operation succeeds, **Then** an `invoice_review:completed` event is emitted

---

### Edge Cases

- What happens when an invoice is partially processed (some fields extracted, others missing)? → Fields display as "N/A" in the UI
- How does the system handle concurrent edits of the same review? → Ecto optimistic locking via timestamps
- What happens when the extracted_content table has corrupted or invalid data? → ReviewDecision stores original_data as a snapshot for reference
- What if a user tries to access a review they don't own? → Authorization check in Review.get_review_decision/2 returns {:error, reason}

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display all review decisions for invoices belonging to the current user via `/reviews`
- **FR-002**: System MUST allow users to view detailed extracted data for each invoice at `/reviews/:id`
- **FR-003**: Users MUST be able to update review status (pending, approved, rejected, amended) and save changes
- **FR-004**: Users MUST be able to edit extracted data fields (invoice_number, invoice_date, issuer, currency, amount_to_pay_cents, reason_for_payment) via `/reviews/:id/edit`
- **FR-005**: System MUST automatically create ReviewDecision records with `review_status: "pending"` when OCR/LLM processing succeeds
- **FR-006**: System MUST automatically create ReviewDecision records with `review_status: "failed"` when OCR/LLM processing fails
- **FR-007**: System MUST emit "invoice_review:completed" event with invoice data, status, and user_id after review completion
- **FR-008**: System MUST maintain decoupled architecture - Review context subscribes to OCR events but does not modify OCR pipeline
- **FR-009**: Users MUST only be able to review invoices from documents that belong to them (document.user_id = current_user.id)

### Key Entities *(include if feature involves data)*

- **ExtractedContent**: Represents OCR/LLM processed invoice data. Fields: `id`, `document_id`, `user_id`, `extracted_data` (embedded), `status`, `analysis`, `error_details`, `inserted_at`, `updated_at`
- **ReviewDecision**: Tracks user review decisions. Fields: `id`, `extracted_content_id`, `user_id`, `review_status`, `decision_type`, `decision_data` (map), `original_data` (map), `review_notes`, `review_completed_at`, `status`, `inserted_at`, `updated_at`
- **EventLog**: Audit trail for review-related events. Fields: `id`, `event_type`, `invoice_id`, `user_id`, `metadata`, `status`, `inserted_at`, `updated_at`

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% data integrity preserved during review operations - achieved via Ecto transactions
- **SC-002**: 0% data loss or corruption in approved invoice data - achieved via proper schema validation and foreign key constraints
- **SC-003**: All review decisions properly audited and traceable - achieved via EventLog table and ReviewDecision timestamps

## Clarifications

### Session 2026-03-18

- Q: How should document ownership be determined and what are the permission rules for invoice review? → A: Document ownership based on uploader (document.user_id). Review access requires matching user_id. Admin override capability is noted for future implementation.
- Q: What event should be emitted after approval/rejection and what data should it contain? → A: "invoice_review:completed" event with invoice_id, status, user_id, decision_data, timestamp
- Q: What measurable success criteria should be defined for this feature? → A: Data integrity preserved during review operations

## Assumptions

- The extracted_content table exists from the 001-persist-ocr-data feature
- Document ownership is determined by the user who uploaded/created the document (document.user_id)
- OCR worker emits events on processing completion (success/failure)
- Users have appropriate permissions to review invoices from their own documents
- The review interface is implemented as Phoenix LiveView components
- PubSub is used for event distribution (Phoenix.PubSub)

## Dependencies

- 001-persist-ocr-data feature (extracted_content table and event system)
- Phoenix web framework for UI implementation
- Existing authentication system for user permissions, using Phoenix's scope

## Constraints

- Must remain decoupled from other application components
- Must not modify the existing OCR/LLM processing pipeline (events are consumed, not modified)
- Must maintain data integrity during concurrent operations
