# Research: Persist Extracted OCR/LLM Content

**Feature**: 001-persist-ocr-data  
**Date**: 2026-03-16  
**Status**: Completed

## Research Questions & Decisions

### 1. Storage Strategy

**Question**: What's the optimal database schema for storing extracted content with document associations?

**Decision**: Create a dedicated `extracted_content` table with foreign key to documents table

**Rationale**:
- Maintains data integrity through foreign key constraints
- Enables efficient queries by document, status, or timestamp
- Follows relational database best practices
- Allows for complex queries and aggregations
- Supports the requirement for historical data preservation

**Alternatives Considered**:
- **JSON field in documents table**: Less query flexibility, harder to index specific fields, doesn't scale well for large datasets
- **Separate database**: Unnecessary complexity, harder to maintain transactions, increased operational overhead
- **NoSQL database**: Overkill for this use case, loses relational benefits, not aligned with existing infrastructure

**References**:
- Ecto Association documentation
- PostgreSQL foreign key best practices
- Phoenix context patterns

### 2. Duplicate Document Handling

**Question**: How should the system handle duplicate document processing?

**Decision**: Create new extraction entries for each processing run

**Rationale**:
- Preserves historical data for audit and comparison purposes
- Allows tracking of extraction quality improvements over time
- Matches stakeholder requirement to maintain historical analysis capability
- Provides flexibility for A/B testing different extraction models
- Enables trend analysis on extraction performance

**Alternatives Considered**:
- **Overwrite existing entries**: Loses historical data, prevents comparison between runs, contradicts stakeholder requirements
- **Skip processing for duplicates**: Loses potential improvements from new processing, requires complex duplicate detection
- **Hybrid approach (configurable)**: Adds unnecessary complexity, stakeholder requirements favor historical preservation

**Implementation Notes**:
- Each extraction run gets a new record with timestamp
- Add `current` flag if needed for "latest" queries
- Consider adding `extraction_version` field for tracking model improvements

### 3. Error Information Storage

**Question**: What error information should be stored for failed extractions?

**Decision**: Store error type, message, stack trace, and timestamp

**Rationale**:
- Provides sufficient information for debugging without being overwhelming
- Enables trend analysis on failure patterns
- Supports customer support with detailed error context
- Balances storage requirements with diagnostic needs
- Aligns with common error handling patterns in the codebase

**Alternatives Considered**:
- **Full error dump**: Too verbose, could contain sensitive information, excessive storage usage
- **Minimal error code**: Insufficient for debugging, poor developer experience
- **External error logging**: Separates error context from extraction data, harder to correlate
- **No error storage**: Loses valuable debugging information, poor operational visibility

**Data Fields**:
- `error_type`: Category of error (e.g., "ocr_failure", "llm_timeout")
- `error_message`: Human-readable error description
- `stack_trace`: Relevant stack trace (sanitized)
- `error_timestamp`: When the error occurred
- `retry_count`: Number of retry attempts

### 4. Content Size Limits

**Question**: What's the appropriate maximum size for extracted content?

**Decision**: 10MB per document

**Rationale**:
- Balances support for large documents with storage efficiency
- Matches stakeholder input and typical document sizes
- Provides headroom for complex documents with extensive text
- Prevents abuse while accommodating legitimate use cases
- Aligns with common database BLOB/JSON size recommendations

**Alternatives Considered**:
- **Unlimited**: Risk of storage abuse, potential performance issues, harder to manage
- **1MB**: Too restrictive for many real-world documents, would require document splitting
- **5MB**: Might be too limiting for complex technical documents
- **50MB**: Excessive for most use cases, increases storage costs unnecessarily

**Implementation Considerations**:
- Validate content size before storage
- Provide clear error messages when limit exceeded
- Consider compression for large text content
- Monitor actual usage patterns for future adjustments

### 5. Data Retention Period

**Question**: What retention period should apply to extracted content?

**Decision**: 5 years

**Rationale**:
- Supports medium-term trend analysis requirements
- Matches stakeholder requirement for historical analysis
- Balances storage costs with business value
- Aligns with common compliance requirements for financial documents
- Provides sufficient data for machine learning model improvement

**Alternatives Considered**:
- **Permanent**: Unbounded storage growth, increasing costs, potential compliance issues
- **1 year**: Too short for meaningful trend analysis, contradicts stakeholder needs
- **2 years**: Still too short for many analytical use cases
- **10 years**: Excessive for most use cases, higher storage costs
- **Configurable per document**: Adds complexity, stakeholder requirements favor consistency

**Implementation Strategy**:
- Use database-level partitioning by year
- Implement automated cleanup job
- Provide admin interface for retention policy management
- Consider soft delete pattern for compliance requirements

## Best Practices Research

### Ecto Schema Design with JSON Fields

**Finding**: Use `:map` type for structured JSON data, `:string` for raw JSON strings

**Application**:
- Use `:map` for `ocr_content` and `llm_content` fields
- This provides type safety and query capabilities
- Ecto automatically handles JSON serialization/deserialization
- Supports validation and changesets on nested data

**Code Example**:
```elixir
schema "extracted_content" do
  field :ocr_content, :map  # Structured OCR results
  field :llm_content, :map  # Structured LLM analysis
  # ... other fields
end
```

**Benefits**:
- Type-safe access to nested data
- Query capabilities on JSON fields
- Automatic validation
- Clean integration with Phoenix

### Phoenix Context Organization

**Finding**: Create separate context module for extracted content management

**Application**: New `ExtractedContent` context following Phoenix conventions

**Recommended Structure**:
```elixir
# lib/zaimu_tomo/document_processing/extracted_content.ex

defmodule ZaimuTomo.DocumentProcessing.ExtractedContent do
  alias ZaimuTomo.Repo
  alias ZaimuTomo.DocumentProcessing.ExtractedContent
  
  # Core functions
  def create_extracted_content(attrs) do
    # Implementation
  end
  
  def get_by_document(document_id) do
    # Implementation
  end
  
  def list_extracted_content(filters) do
    # Implementation
  end
end
```

**Benefits**:
- Clear separation of concerns
- Follows Phoenix context patterns
- Easy to test in isolation
- Scalable for future enhancements

### Database Indexing Strategies

**Finding**: Index foreign keys and frequently queried fields

**Application**: Index `document_id`, `status`, and `extraction_timestamp`

**Recommended Indexes**:
```elixir
# In migration file
create index(:extracted_content, [:document_id])
create index(:extracted_content, [:status])
create index(:extracted_content, [:extraction_timestamp])
create index(:extracted_content, [:document_id, :extraction_timestamp])
```

**Query Optimization**:
- Document-based queries: `WHERE document_id = ?`
- Status filtering: `WHERE status = ?`
- Time-range queries: `WHERE extraction_timestamp BETWEEN ? AND ?`
- Combined queries: `WHERE document_id = ? AND status = ?`

**Monitoring**:
- Track index usage statistics
- Monitor query performance
- Adjust indexes based on actual usage patterns

### Error Recovery Patterns

**Finding**: Implement exponential backoff with maximum retry limit

**Application**: Add retry mechanism with 3 attempts and increasing delays

**Recommended Implementation**:
```elixir
defp with_retry(operation, max_attempts \ 3, initial_delay \ 1000) do
  with_retry(operation, max_attempts, initial_delay, 1)
end

defp with_retry(operation, max_attempts, delay, attempt) do
  case operation.() do
    {:ok, result} -> {:ok, result}
    {:error, reason} when attempt >= max_attempts -> {:error, reason}
    {:error, reason} ->
      Process.sleep(delay)
      with_retry(operation, max_attempts, delay * 2, attempt + 1)
  end
end
```

**Configuration**:
- Max attempts: 3 (prevents infinite retries)
- Initial delay: 1 second
- Backoff factor: 2x (exponential increase)
- Max total delay: ~7 seconds (1 + 2 + 4)

**Benefits**:
- Handles transient failures gracefully
- Prevents system overload from rapid retries
- Provides reasonable recovery for temporary issues
- Easy to configure and test

### Event Consistency Patterns

**Finding**: Emit events only after successful database transactions

**Application**: Wrap event emission in Ecto transaction callbacks

**Recommended Implementation**:
```elixir
def create_and_emit_extracted_content(attrs) do
  Repo.transaction(fn ->
    # Create the extracted content
    case ExtractedContent.create_extracted_content(attrs) do
      {:ok, content} ->
        # Emit success event
        ZaimuTomo.PubSub.emit("document_processing:success", %{
          document_id: content.document_id,
          extraction_id: content.id,
          timestamp: content.extraction_timestamp,
          status: content.status
        })
        {:ok, content}
      
      {:error, reason} ->
        # Emit failure event
        ZaimuTomo.PubSub.emit("document_processing:failed", %{
          document_id: attrs.document_id,
          timestamp: DateTime.utc_now(),
          status: "failed",
          error_details: reason
        })
        {:error, reason}
    end
  end)
end
```

**Benefits**:
- Ensures events only for persisted data
- Maintains consistency between database and events
- Prevents orphaned events
- Provides reliable audit trail

## Additional Research

### Content Validation Strategies

**Recommendation**: Implement multi-layer validation

**Layers**:
1. **Schema validation**: Ecto changeset validations
2. **Size validation**: Check content size before storage
3. **Format validation**: Verify JSON structure
4. **Business rules**: Document-specific constraints

**Implementation**:
```elixir
defp validate_extracted_content(attrs) do
  %attrs{}
  |> cast(attrs, [:document_id, :ocr_content, :llm_content, :status])
  |> validate_required([:document_id, :ocr_content, :status])
  |> validate_inclusion(:status, ["success", "partial", "failed"])
  |> validate_content_size(:ocr_content, max_bytes: 10_000_000)
  |> validate_content_size(:llm_content, max_bytes: 10_000_000)
  |> validate_json_structure(:ocr_content)
  |> validate_json_structure(:llm_content)
end
```

### Query Performance Optimization

**Recommendation**: Implement pagination and efficient filtering

**Strategies**:
- **Cursor-based pagination**: Better for large datasets
- **Index-backed filtering**: Ensure all filter fields are indexed
- **Selective loading**: Only load needed fields
- **Query optimization**: Use Ecto's query builder effectively

**Example Query**:
```elixir
def list_extracted_content(%{status: status, limit: limit, after: after_id}) do
  query = from ec in ExtractedContent,
          where: is_nil(status) or ec.status == ^status,
          order_by: [desc: :id]
  
  if after_id do
    query = where(query, ec.id < ^after_id)
  end
  
  query
  |> limit(^limit)
  |> Repo.all()
end
```

### Data Migration Strategy

**Recommendation**: Implement safe, reversible migrations

**Approach**:
- Use Ecto migrations with proper up/down functions
- Test migrations in staging environment
- Implement data backfill for existing documents
- Provide rollback capability

**Migration Example**:
```elixir
defmodule ZaimuTomo.Repo.Migrations.CreateExtractedContent do
  use Ecto.Migration
  
  def change do
    create table(:extracted_content) do
      add :document_id, references(:documents, on_delete: :delete_all)
      add :ocr_content, :map
      add :llm_content, :map
      add :confidence_score, :float
      add :status, :string
      add :error_details, :map
      add :ocr_version, :string
      add :llm_version, :string
      add :processing_duration_ms, :integer
      add :extraction_timestamp, :naive_datetime
      
      timestamps()
    end
    
    create index(:extracted_content, [:document_id])
    create index(:extracted_content, [:status])
    create index(:extracted_content, [:extraction_timestamp])
  end
end
```

## Conclusion

All research questions have been resolved with clear decisions and rationales. The chosen approaches align with:
- Existing technical stack (Elixir/Phoenix/Ecto/PostgreSQL)
- Stakeholder requirements from the specification
- Industry best practices for web applications
- Performance and scalability goals

The implementation can proceed with confidence based on this research foundation.
