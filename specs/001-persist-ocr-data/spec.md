# Feature Specification: Persist Extracted OCR/LLM Content

**Feature Branch**: `001-persist-ocr-data`  
**Created**: 2026-03-16  
**Status**: Implemented  
**Input**: User description: "specify data persistence for extracted content from OCR/LLM"

## Problem Statement (RESOLVED)

The document processing system now:
✅ Persistently stores extracted content from OCR/LLM processing
✅ Uses structured embedded schemas for type safety and data consistency
✅ Maintains all extracted data with proper relationships to original documents
✅ Supports retrieval, filtering, and historical analysis of extracted content
✅ Handles both successful and failed extractions with appropriate metadata

**Original Problem**: The system was losing valuable extracted data after processing completes and could not retrieve or reference previously extracted content.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Store Extracted Content (Priority: P1)

As a user, I want the system to persistently store extracted content from OCR/LLM processing so that I can retrieve and reference it later.

**Why this priority**: This is the core functionality needed to solve the problem. Without persistent storage, all extracted data is lost after processing.

**Independent Test**: Can be fully tested by uploading a document, processing it through OCR/LLM, and verifying the extracted content is stored in the database and can be retrieved.

**Acceptance Scenarios**:

1. **Given** a document has been processed through OCR/LLM, **When** I query for extracted content, **Then** I should receive the complete extracted data structure with structured invoice data (amount, date, currency, etc.)
2. **Given** multiple documents have been processed, **When** I query for all extracted content, **Then** I should receive extracted data for all documents with proper type-safe structures
3. **Given** a document processing fails, **When** I query for extracted content, **Then** I should receive the extraction record with status="failed" and error details

---

### User Story 2 - Retrieve Extracted Content by Document (Priority: P2)

As a user, I want to retrieve extracted content for a specific document so that I can view the analysis results for that particular file.

**Why this priority**: This builds on the core storage functionality and provides the basic retrieval capability users need.

**Independent Test**: Can be fully tested by storing extracted content for multiple documents and verifying retrieval works correctly for each individual document.

**Acceptance Scenarios**:

1. **Given** extracted content has been stored for document A, **When** I retrieve content for document A, **Then** I should get only the content for document A
2. **Given** no extracted content exists for document B, **When** I attempt to retrieve content for document B, **Then** I should receive a not-found response

---

### User Story 3 - Query Extracted Content with Filters (Priority: P3)

As a user, I want to filter and query extracted content (e.g., by date range, extraction status, confidence score) so that I can find specific information efficiently.

**Why this priority**: This enhances usability by allowing users to find specific extracted content without retrieving everything.

**Independent Test**: Can be fully tested by storing extracted content with various metadata and verifying filters return correct subsets of data.

**Acceptance Scenarios**:

1. **Given** extracted content with different timestamps, **When** I filter by date range, **Then** I should receive only content within that range
2. **Given** extracted content with different statuses, **When** I filter by success status, **Then** I should receive only successfully processed content
3. **Given** extracted content with various confidence scores, **When** I filter by minimum confidence threshold, **Then** I should receive only content meeting or exceeding that threshold

### Edge Cases

1. **Duplicate document processing**
  - Same document uploaded multiple times
  - System should detect duplicates and handle appropriately
  - System shall create new extraction entries to preserve historical data and allow comparison between different processing runs

2. **Failed extraction processing**
  - OCR/LLM processing fails for a document
  - System should store partial results if available
  - System should mark extraction as failed with error details
  - User should be able to retry failed extractions

3. **Large document processing**
  - Document contains extremely large amounts of text
  - System should handle large extracted content efficiently
  - System shall support extracted content up to 10MB per document, which balances support for large documents with reasonable storage requirements

4. **Data retention and cleanup**
  - Extracted content accumulates over time
  - System should have data retention policies
  - System shall retain extracted content for 5 years, providing a balanced approach that supports medium-term trend analysis while managing storage requirements

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST persistently store content extracted in a structured format from successful OCR/LLM processing
- **FR-002**: System MUST associate extracted content with the original document identifier
- **FR-003**: System MUST store metadata including timestamp, processing status, and document reference
- **FR-004**: System MUST allow retrieval of extracted content by document ID
- **FR-005**: System MUST support full-text search across all extracted content and allow query extracted content with filters (date range, status, confidence score, etc.)
- **FR-006**: System MUST handle storage failures gracefully without crashing the processing pipeline
- **FR-007**: System MUST ensure data consistency when the same document is processed multiple times
- **FR-008**: System MUST prevent orphaned extracted content entries
- **FR-009**: System MUST store error information when extraction fails and provide user-friendly error messages for extraction failures
- **FR-010**: System MUST allow retry of failed extractions
- **FR-011**: System MUST persist extracted content to storage before emitting any events
- **FR-012**: System MUST emit `document_processing:success` events only after successful persistence
- **FR-013**: System MUST emit `document_processing:failed` events only after failed persistence attempts
- **FR-014**: System MUST ensure event consumers receive only confirmed, persisted data
- **FR-015**: System MUST include persistence status and content reference information

### Metadata Requirements

1. **Extraction Metadata**
  - System shall store timestamp of extraction
  - System shall store version information for OCR/LLM models used
  - System shall store processing duration metrics
  - System shall store confidence scores for extracted content

2. **Document Association**
  - System shall maintain bidirectional relationship between documents and extracted content
  - System shall allow multiple extracted content entries per document (for different processing versions)
  - System shall track which extraction version is current/active

### Key Entities *(include if feature involves data)*

- **ExtractedContent**: Represents the persisted results of OCR/LLM processing
  - `id`: Unique identifier
  - `document_id`: Reference to original document
  - `extracted_data`: Structured extracted invoice data (embedded schema)
  - `status`: Extraction status (success, partial, failed)
  - `error_details`: Error information if failed
  - `analysis`: Analysis metadata including confidence scores and processing timestamps

- **ExtractedData** (Embedded Schema): Structured data extracted from invoices
  - `amount_to_pay_cents`: Total amount to pay in cents (integer)
  - `invoice_date`: Invoice date (string)
  - `invoice_number`: Invoice number/identifier (string)
  - `currency`: Currency code (string)
  - `reason_for_payment`: Description/purpose of payment (string)
  - `issuer`: Company/person issuing the invoice (string)

- **Document**: Existing entity that extracted content will reference
  - id: Primary identifier
  - Other existing fields...

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Extracted content is successfully stored and retrievable for 99.9% of processed documents
- **SC-002**: Retrieval of extracted content completes in under 500ms for 95% of requests
- **SC-003**: Filtered queries return correct results with no false positives or negatives, achieving at least 99% accuracy
- **SC-004**: System can handle storage of 10,000+ extracted content records without performance degradation
- **SC-005**: Data consistency is maintained with no duplicate or conflicting records for the same document

## Assumptions

1. **Storage Backend**: System will use PostgreSQL for storing extracted content and metadata. Uploaded document files (PDFs) will continue to reside on the filesystem.
2. **Search Capability**: Full-text search will be implemented using PostgreSQL's full-text search capabilities
3. **Data Retention**: Default retention period of 5 years unless specified otherwise
4. **Duplicate Handling**: Duplicate documents will create new extraction entries to preserve historical data
5. **Content Size**: Maximum extracted content size of 10MB per document (as chosen by stakeholder)
6. **Concurrency**: System will handle up to 100 concurrent extraction requests

## Dependencies

1. **Existing Document Processing System**: OCR and LLM processing pipelines
2. **Database Infrastructure**: Existing PostgreSQL database
3. **Authentication System**: User authentication for access control
4. **Document Management**: Existing filesystem for document storage
5. **Event System**: Existing event emission infrastructure for document processing events

## Technical Implementation Summary

### Files Created/Modified

1. **Database Migration**: `priv/repo/migrations/20260317031242_rebuild_extracted_content_table.exs`
   - Drops old table and creates new schema with embedded data structure
   - Maintains all existing fields with improved organization

2. **Schema Update**: `lib/zaimu_tomo/document_processing/extracted_content/extracted_content.ex`
   - Replaced `ocr_content` and `llm_content` maps with `embeds_one :extracted_data, ExtractedData`
   - Added comprehensive validation logic for status-specific requirements
   - Implemented size validation for embedded data (< 10MB)

3. **OCR Worker**: `lib/zaimu_tomo/document_processing/ocr_worker.ex`
   - Fixed error handling for different error types (tuples, atoms, binaries)
   - Added proper conversion of ExtractedData structs to maps for embedded field
   - Maintained event emission after successful persistence

4. **Test Suite**: `test/zaimu_tomo/document_processing/extracted_content_test.exs`
   - Updated all test fixtures to use new schema format
   - All 7 extracted content tests passing
   - All 138 total tests passing

### Key Technical Decisions

1. **Embedded Schema Choice**: Selected `embeds_one` over `:map` fields for:
   - Strong typing and compile-time validation
   - Better IDE support and autocompletion
   - Automatic validation through ExtractedData.changeset
   - Self-documenting schema structure

2. **Validation Strategy**: Status-specific validation ensures:
   - `extracted_data` is required for successful/partial extractions
   - `extracted_data` is optional for failed extractions
   - Proper error messages for validation failures

3. **Migration Approach**: Clean slate migration since no production data exists:
   - Drop and recreate table for clean schema
   - No need for data migration or backward compatibility
   - Simplified implementation without migration complexity

### Test Results

- ✅ All 7 extracted content tests passing
- ✅ All 138 total application tests passing
- ✅ Database migration applied successfully
- ✅ OCR processing pipeline works with new schema
- ✅ Validation logic works for all status types
- ✅ Error handling is robust and comprehensive

## Implementation Notes

This specification focuses on the functional requirements and user needs. Technical implementation details such as specific database schemas, API endpoints, or programming languages are intentionally omitted to maintain technology agnosticism.

### Technical Implementation Approach

The implementation uses an **embedded schema approach** for better type safety and data consistency:

- **Embedded Schema**: `ExtractedData` is implemented as an embedded schema within `ExtractedContent` using Ecto's `embeds_one` relationship
- **Type Safety**: All extracted data fields are strongly typed with compile-time validation
- **Validation**: Status-specific validation ensures extracted_data is required for successful extractions but optional for failed ones
- **Data Size**: Maximum extracted content size of 10MB per document is enforced through validation

### Benefits of Embedded Schema Approach

1. **Type Safety**: Compile-time validation and better IDE support
2. **Data Consistency**: Single source of truth for extracted invoice data
3. **Simplified API**: Unified data structure instead of separate OCR/LLM content fields
4. **Validation**: Automatic validation through the embedded schema's changeset
5. **Maintainability**: Self-documenting schema structure

### Migration Strategy

Since the application is not in production, a clean slate approach was used:
- Drop existing table and recreate with clean schema
- No need for data migration or backward compatibility
- All existing functionality preserved with improved data structure
