# Research: Review OCR/LLM Processed Data

## Technical Decisions

### 1. Document Ownership Implementation

**Decision**: Implement document ownership based on uploader with admin override capability (noted for future)

**Rationale**: 
- Aligns with FR-009 requirement for user-specific document access
- Provides necessary flexibility for administrative oversight
- Follows common patterns in document management systems
- Maintains security by default (users can only see their own documents)

**Implementation Approach**:
- Add `user_id` field to extracted_content table (completed in migration `20260319050900_add_user_id_to_extracted_content.exs`)
- OCR worker passes `user_id: document.user_id` when creating ExtractedContent
- Review context filters by current user's ID when listing reviews
- Authorization check in `Review.get_review_decision/2` verifies user owns the document
- Admin override capability is documented but not yet implemented

**Actual Implementation**:
```elixir
# In ocr_worker.ex
ExtractedContentContext.create_extracted_content(%{
  document_id: document.id,
  user_id: document.user_id,  # Passed from document
  extracted_data: extracted_data,
  status: "success"
})

# In review.ex
list_review_decisions(user_id) do
  from rd in ReviewDecision,
  join: ec in ExtractedContent, on: ec.id == rd.extracted_content_id,
  where: ec.user_id == ^user_id,  # Filter by owner
  order_by: [asc: rd.review_status == "pending", desc: rd.inserted_at]
end
```

**Alternatives Considered**:
- Organization-based ownership: Too complex for current requirements
- Explicit sharing system: Overkill for initial implementation
- No ownership restrictions: Violates security requirements

---

### 2. Event System for Review Completion

**Decision**: Emit "invoice_review:completed" event with invoice_id, status, user_id, decision_data, timestamp

**Rationale**:
- Provides necessary information for downstream processing
- Follows existing event naming conventions in the system
- Lightweight payload that can be extended later
- Enables audit trail and integration with other systems

**Implementation Approach**:
- Use existing Phoenix PubSub system for event dispatch
- Emit event after database transaction completes successfully
- Store event data in database for audit purposes (EventLog table)
- Event emitted from `Review.approve_invoice/3`, `Review.reject_invoice/3`, `Review.amend_invoice/3`

**Actual Implementation**:
```elixir
# In review.ex
defp emit_review_completed_event(invoice, review_decision, status) do
  payload = %{
    invoice_id: invoice.id,
    status: status,
    user_id: review_decision.user_id,
    decision_data: review_decision.decision_data,
    timestamp: DateTime.utc_now()
  }
  Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "invoice_review:completed", payload)
end
```

**Alternatives Considered**:
- Simple approval/rejection events: Less flexible for future needs
- Detailed event with full invoice data: Unnecessary data duplication
- No event emission: Would break decoupling requirements

---

### 3. Data Integrity Preservation

**Decision**: Implement comprehensive data integrity measures

**Rationale**:
- Critical for financial data accuracy
- Required by success criteria (SC-001, SC-002, SC-003)
- Prevents data corruption during concurrent operations
- Provides audit trail for compliance

**Implementation Approach**:
- Use Ecto transactions for all review operations
- Implement optimistic locking for concurrent edits (via timestamps)
- Create comprehensive audit log via EventLog table
- Add data validation at both UI and database levels
- Store snapshot of original data in `original_data` field

**Actual Implementation**:
```elixir
# Snapshot preservation in create_review_decision/2
%ReviewDecision{
  extracted_content_id: invoice.id,
  user_id: user_id,
  original_data: Map.from_struct(invoice.extracted_data),  # Snapshot
  decision_data: decision_data,  # User's amended data
  review_status: "completed",
  # ...
}
```

**Alternatives Considered**:
- Basic database constraints only: Insufficient for financial data
- No special integrity measures: Unacceptable risk
- External audit system: Too complex for initial implementation

---

### 4. UI Implementation Approach

**Decision**: Use Phoenix LiveView for interactive review interface

**Rationale**:
- Aligns with existing Phoenix framework usage
- Provides real-time updates without full page reloads
- Good performance characteristics for form-heavy interfaces
- Maintains server-side rendering for SEO and accessibility

**Implementation Approach**:
- Create LiveView component for invoice review interface
- Use existing Tailwind CSS classes for styling
- Implement real-time updates using LiveView's built-in capabilities
- Add client-side validation for better user experience
- Follow existing authentication and authorization patterns

**Actual Implementation**:
```elixir
# lib/zaimu_tomo_web/live/review_live/
# index.ex - Lists all reviews with pending first
# show.ex - Displays individual review details
# edit.ex - Allows editing decision_data fields
```

**Alternatives Considered**:
- Traditional MVC controllers: Less interactive
- JavaScript framework (React/Vue): Overkill, breaks existing patterns
- Static HTML forms: Poor user experience

---

### 5. Event Consumption for Document Processing

**Decision**: Use direct creation pattern with EventConsumer as fallback

**Rationale**:
- Primary path: OCR worker directly creates ReviewDecision after ExtractedContent creation
- Provides maximum reliability (ReviewDecision always created when OCR completes)
- Simpler than event-driven approach for critical path
- EventConsumer still implemented for future enhancements and `invoice_review:completed` events

**Implementation Approach**:
- OCR worker calls `create_review_decision/3` directly after ExtractedContent creation
- Same for `create_failed_review_decision/3` on failure
- EventConsumer subscribes to `document_processing:success` and `document_processing:failed` topics
- EventConsumer uses `Phoenix.PubSub.subscribe/2` and `Phoenix.PubSub.broadcast/3`
- Events include `user_id` for proper ownership

**Actual Implementation**:
```elixir
# In ocr_worker.ex - Direct creation (primary path)
def persist_and_emit_success(document, extracted_data) do
  # ... create ExtractedContent ...
  {:ok, _review_decision} = create_review_decision(content, document.user_id, extracted_data)
  # ... emit event ...
end

# In review/event_consumer.ex - Event-driven (fallback/future)
def init(_) do
  Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:success")
  Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, "document_processing:failed")
  {:ok, %{}}
end

def handle_info({:broadcast, "document_processing:success", payload}, socket) do
  ZaimuTomo.Review.handle_document_processing_success(payload)
  {:noreply, socket}
end
```

**Exact Event Payload Structures** (from ocr_worker.ex):

**Success Event**:
```elixir
%{
  document_id: document.id,        # integer
  extraction_id: content.id,        # integer
  user_id: document.user_id,       # integer - ADDED for ownership
  status: :completed,               # atom
  data: extracted_data,              # map
  timestamp: DateTime.utc_now()    # DateTime
}
```

**Failure Event**:
```elixir
%{
  document_id: document.id,        # integer
  extraction_id: content.id,        # integer
  user_id: document.user_id,       # integer - ADDED for ownership
  status: :failed,                  # atom
  error: error,                     # any
  timestamp: DateTime.utc_now()    # DateTime
}
```

**Compatibility Notes**:
- **user_id field**: Added to payloads to ensure proper ownership tracking
- **Refer to**: lib/zaimu_tomo/document_processing/ocr_worker.ex lines 25-50
- EventConsumer is started in application supervision tree but direct creation is primary path

**Alternatives Considered**:
- Creating new events: Unnecessary duplication, breaks existing consumers
- Polling database: Inefficient, poor user experience
- Direct database triggers: Tight coupling, hard to debug

---

### 6. Form Handling for Nested Map Fields

**Decision**: Use standalone inputs with `name` attributes for nested decision_data map fields

**Rationale**:
- Ecto FormField doesn't support nested atom access for map types (e.g., `@form[:decision_data][:invoice_number]` causes KeyError)
- Standalone inputs with `name` attributes allow proper parameter nesting
- Custom `extract_nested_params/2` function handles parameter extraction

**Implementation Approach**:
- Inputs use `name="decision_data[field_name]"` format
- `handle_event` extracts nested params using regex/custom function
- Initial values pre-populated from `original_data` in mount

**Actual Implementation**:
```elixir
# In edit.html.heex
<.input name="decision_data[invoice_number]" value={@decision_data["invoice_number"] || ""} label="Invoice Number" />

# In edit.ex
defp extract_nested_params(params, prefix) do
  params
  |> Enum.filter(fn {k, _} -> String.starts_with?(k, "#{prefix}[") end)
  |> Enum.map(fn {k, v} ->
    key = k |> String.replace("#{prefix}[", "") |> String.replace("]", "")
    {key, v}
  end)
  |> Map.new()
end

def handle_event("save", %{"review_decision" => params}, socket) do
  decision_data = extract_nested_params(params, "decision_data")
  attrs = %{decision_data: decision_data, review_status: params["review_status"], ...}
  # ... update review_decision
end
```

**Alternatives Considered**:
- Using form `for` attribute: Doesn't work with nested map access
- Custom form component: More complex than needed
- JavaScript parameter transformation: Breaks server-side rendering benefits

---

## Best Practices Research

### Phoenix LiveView Patterns

**Findings Applied**:
- Use `phx-update="ignore"` for static elements that shouldn't re-render
- Use `stream/2` for efficient rendering of collections (reviews list)
- Use `assign/3` for socket state management
- Follow the "single source of truth" pattern for form data

### Ecto Data Modeling

**Findings Applied**:
- Use `belongs_to` for review decision to extracted content relationship
- Add database constraints and foreign keys for data integrity
- Use Ecto changesets for validation
- Implement proper indexes for query performance
- Use `Map.from_struct/1` to convert structs to maps for storage in map fields

### Event-Driven Architecture in Elixir

**Findings Applied**:
- Use Phoenix PubSub for local event distribution
- Use GenServer for event consumers
- Implement proper message handling with pattern matching
- Use `:telemetry` for event monitoring (available for future use)

### Financial Data Security

**Findings Applied**:
- Implement proper authorization at data access layer
- Use HTTPS for all communications (Phoenix default)
- Implement CSRF protection for forms (Phoenix default)
- Add validation at multiple levels

## Implementation Notes

### Direct Creation Pattern Rationale

The decision to use **direct creation** (OCR worker creates ReviewDecision directly) instead of **event-driven creation** (EventConsumer listens for events and creates ReviewDecision) was made for the following reasons:

1. **Reliability**: Direct creation ensures ReviewDecision is always created when OCR completes - no risk of lost events
2. **Simplicity**: Fewer moving parts, easier to debug and understand
3. **Atomicity**: ReviewDecision creation happens in the same process as OCR completion
4. **Immediate availability**: Reviews appear instantly without event processing delay
5. **Decoupling maintained**: The Review context still maintains its own schemas, logic, and can be used independently

The EventConsumer is still implemented and started in the supervision tree because:
1. It provides a fallback mechanism if direct creation fails
2. It enables future event-driven enhancements
3. It handles `invoice_review:completed` events for audit purposes
4. It demonstrates the event-driven architecture pattern for future use

### Key Technical Decisions Summary

| Decision | Approach | Rationale |
|----------|----------|-----------|
| Document ownership | user_id on extracted_content | Security, auditability |
| Review data storage | Separate review_decisions table | Normalization, clarity |
| Automatic review creation | Direct creation by OCR worker | Reliability, simplicity |
| Form nested fields | Standalone inputs with name attributes | Ecto FormField limitation |
| Date formatting | DateTime.to_iso8601/1 | Consistency, reliability |
| Event system | Phoenix PubSub | Existing infrastructure |

## Open Questions

None - all critical technical decisions have been resolved and implemented.
