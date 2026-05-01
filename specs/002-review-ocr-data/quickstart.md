# Quickstart: Review OCR/LLM Processed Data

## Overview

This guide helps you quickly understand and test the invoice review feature for OCR/LLM processed data.

## Prerequisites

- Phoenix application running
- OCR/LLM processing pipeline operational
- User authentication working
- PostgreSQL database available
- Migrations run: `mix ecto.migrate`

## Setup

### 1. Database Migration

Run the migrations to set up required tables:

```bash
mix ecto.migrate
```

The following migrations will be applied:
- `20260319050855_create_review_decisions.exs` - Creates review_decisions table
- `20260319050858_create_event_logs.exs` - Creates event_logs table
- `20260319050900_add_user_id_to_extracted_content.exs` - Adds user_id to extracted_content table

### 2. Configuration

No additional configuration is required. The feature uses existing Phoenix authentication and PubSub systems.

### 3. Start the Application

The EventConsumer is automatically started with the application via the supervision tree in `lib/zaimu_tomo/application.ex`.

```bash
mix phx.server
```

## Testing the Feature

### 1. Upload a Document

1. Navigate to `/documents/new` in your browser
2. Upload a document file
3. The OCR processing will automatically:
   - Extract data from the document
   - Create an ExtractedContent record with `user_id` set to the uploader
   - Create a ReviewDecision record with `review_status: "pending"`
   - Emit `document_processing:success` event

### 2. Access the Review Interface

Navigate to: `/reviews`

You should see:
- List of all review decisions for your account
- Status badges (Pending, Approved, Rejected, Amended, Failed) with color coding
- Invoice data: Invoice Number, Issuer, Amount, Date
- Click on any row or "Show" link to view details
- Pending reviews appear first, ordered by creation date

### 3. View Review Details

Navigate to: `/reviews/:id`

You will see:
- Review status and decision type
- All extracted invoice data fields:
  - Invoice Number
  - Invoice Date
  - Issuer
  - Currency
  - Amount to Pay (in cents)
  - Reason for Payment
- Original data vs amended data comparison
- Review notes (if any)
- Timestamps (created, updated)
- "Edit" button to modify the review

### 4. Edit a Review

Navigate to: `/reviews/:id/edit`

You can:
- Update the review status (pending, approved, rejected, amended)
- Update the decision type (initial, approved, rejected, amended, failed)
- Edit all invoice data fields:
  - Invoice Number
  - Invoice Date
  - Issuer
  - Currency
  - Amount to Pay (cents)
  - Reason for Payment
- Add or update review notes
- Click "Save Changes" to persist updates to `decision_data`

**Note**: The edit form uses standalone inputs with `name` attributes (e.g., `name="decision_data[invoice_number]"`) for nested map fields because Ecto FormField doesn't support nested atom access for map types.

### 5. Verify Automatic Review Creation

When you upload a document:

```elixir
# Check that ReviewDecision was created
ZaimuTomo.Review.ReviewDecision
|> where(user_id: current_user.id)
|> where(review_status: "pending")
|> order_by(desc: :inserted_at)
|> first()

# Check the associated ExtractedContent
ZaimuTomo.DocumentProcessing.ExtractedContentContext.get_by_id(review_decision.extracted_content_id)
```

## Common Operations

### List All Reviews for a User

```elixir
ZaimuTomo.Review.list_review_decisions(user_id)
# Returns: List of ReviewDecision structs with associated ExtractedContent, pending first
```

### Get a Specific Review

```elixir
ZaimuTomo.Review.get_review_decision(review_decision_id, current_user.id)
# Returns: {:ok, %ReviewDecision{}} or {:error, reason}
```

### Update a Review

```elixir
attrs = %{
  review_status: "approved",
  decision_type: "approved",
  decision_data: %{
    "invoice_number" => "INV-2024-001",
    "invoice_date" => "2024-01-15",
    "issuer" => "Acme Corp",
    "currency" => "USD",
    "amount_to_pay_cents" => 10000,
    "reason_for_payment" => "Services rendered"
  },
  review_notes: "Approved after verification",
  review_completed_at: DateTime.utc_now(),
  status: "completed"
}

ZaimuTomo.Review.update_review_decision(review_decision, attrs)
```

### Get Review Status Counts

```elixir
ZaimuTomo.Review.get_review_status_counts(user_id)
# Returns: %{pending: n, approved: n, rejected: n, amended: n}
```

## Programmatic API

### Approve an Invoice

```elixir
ZaimuTomo.Review.approve_invoice(extracted_content_id, user_id, "Approved - data verified")
```

### Reject an Invoice

```elixir
ZaimuTomo.Review.reject_invoice(extracted_content_id, user_id, "Rejected - poor scan quality")
```

### Amend Invoice Data

```elixir
ZaimuTomo.Review.amend_invoice(
  extracted_content_id,
  user_id,
  %{
    "invoice_number" => "CORRECTED-001",
    "amount_to_pay_cents" => 15000
  },
  "Amended amount per vendor confirmation"
)
```

### Handle Document Processing Events

The OCR worker automatically handles this, but you can also call directly:

```elixir
# On success
payload = %{
  "document_id" => document.id,
  "extraction_id" => extracted_content.id,
  "user_id" => document.user_id,
  "status" => :completed,
  "data" => extracted_data
}
ZaimuTomo.Review.handle_document_processing_success(payload)

# On failure
payload = %{
  "document_id" => document.id,
  "extraction_id" => extracted_content.id,
  "user_id" => document.user_id,
  "status" => :failed,
  "error" => error
}
ZaimuTomo.Review.handle_document_processing_failure(payload)
```

## Event System

### Events Emitted

1. **`document_processing:success`** - Emitted by OCR worker when extraction succeeds
   - Payload: `%{document_id: integer, extraction_id: integer, user_id: integer, status: :completed, data: map, timestamp: DateTime}`

2. **`document_processing:failed`** - Emitted by OCR worker when extraction fails
   - Payload: `%{document_id: integer, extraction_id: integer, user_id: integer, status: :failed, error: any, timestamp: DateTime}`

3. **`invoice_review:completed`** - Emitted by Review context when a review is completed
   - Payload: `%{invoice_id: integer, status: string, user_id: integer, decision_data: map, timestamp: DateTime}`

### Event Consumer

The `ZaimuTomo.Review.EventConsumer` is started automatically and subscribes to:
- `"document_processing:success"`
- `"document_processing:failed"`

It handles these events to create ReviewDecision records (though the primary path is direct creation by the OCR worker).

## Troubleshooting

### No Invoices Showing Up on /reviews

1. Check you're logged in as the document owner
2. Verify OCR processing completed successfully:
   ```elixir
   ZaimuTomo.DocumentProcessing.ExtractedContent
   |> where(user_id: current_user.id)
   |> Repo.all()
   ```
3. Check ReviewDecision records exist:
   ```elixir
   ZaimuTomo.Review.ReviewDecision
   |> join(:left, [rd], ec in ZaimuTomo.DocumentProcessing.ExtractedContent, on: ec.id == rd.extracted_content_id)
   |> where([_, ec], ec.user_id == ^current_user.id)
   |> Repo.all()
   ```
4. Verify user_id is set correctly on extracted_content:
   ```elixir
   ZaimuTomo.DocumentProcessing.ExtractedContent
   |> where(user_id: current_user.id)
   |> Repo.all()
   ```

### Permission Errors

1. Ensure you're logged in as the document owner
2. Review access is restricted to the document uploader (via `document.user_id`)
3. Admin override capability is noted for future implementation but not yet implemented
4. Check that the ReviewDecision exists and belongs to you:
   ```elixir
   ZaimuTomo.Review.get_review_decision(review_id, current_user.id)
   ```

### Events Not Processing

1. Check event consumer is running (it starts with the application)
2. Verify PubSub is working:
   ```elixir
   Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "test:event", %{test: true})
   ```
3. Check the EventConsumer module is in the supervision tree:
   ```elixir
   # In lib/zaimu_tomo/application.ex
   children = [
     # ...
     ZaimuTomo.Review.EventConsumer
   ]
   ```

## Monitoring

### Key Metrics

```elixir
# Invoices awaiting review
ZaimuTomo.Review.ReviewDecision
|> where(review_status: "pending")
|> join(:left, [rd], ec in ZaimuTomo.DocumentProcessing.ExtractedContent, on: ec.id == rd.extracted_content_id)
|> where([_, ec], ec.user_id == ^user_id)
|> count()

# Review status distribution
ZaimuTomo.Review.get_review_status_counts(user_id)
```

## Development Tips

### Testing with Fake Data

```elixir
# Create test extracted content
{:ok, user} = ZaimuTomo.Accounts.create_user(%{email: "test@test.com", password: "password123"})

{:ok, document} = ZaimuTomo.Documents.create_document(%{filename: "test.pdf", filepath: "test.pdf", user_id: user.id})

# Create extracted content with user_id
extraction_params = %{
  document_id: document.id,
  user_id: user.id,
  extracted_data: %ZaimuTomo.DocumentProcessing.ExtractedData{
    invoice_number: "TEST-001",
    invoice_date: "2024-01-15",
    issuer: "Test Vendor",
    currency: "USD",
    amount_to_pay_cents: 10000,
    reason_for_payment: "Test payment"
  },
  status: "success",
  analysis: %{"confidence" => 0.95}
}

{:ok, content} = ZaimuTomo.DocumentProcessing.ExtractedContentContext.create_extracted_content(extraction_params)

# ReviewDecision will be created automatically by the OCR worker
# Or manually:
{:ok, review_decision} = ZaimuTomo.Review.ReviewDecision.changeset_for_create(%{
  extracted_content_id: content.id,
  user_id: user.id,
  review_status: "pending",
  decision_type: "initial",
  decision_data: %{},
  original_data: Map.from_struct(content.extracted_data)
}) |> ZaimuTomo.Repo.insert()
```

### Bypass Review for Testing

```elixir
# Directly approve (bypasses UI)
{:ok, content} = ZaimuTomo.DocumentProcessing.ExtractedContentContext.get_by_id(extraction_id)
{:ok, _review_decision} = ZaimuTomo.Review.approve_invoice(content.id, user.id, "Auto-approved for testing")
```

## UI Routes

| Route | Purpose | LiveView Module |
|-------|---------|----------------|
| `/reviews` | List all reviews (pending first) | ReviewLive.Index |
| `/reviews/:id` | Show review details | ReviewLive.Show |
| `/reviews/:id/edit` | Edit review data | ReviewLive.Edit |

## Best Practices

1. **Always use authorization**: Verify user owns the document via `document.user_id == current_user.id`
2. **Use transactions** for operations that modify multiple tables
3. **Validate data** at multiple levels (UI, changeset, database)
4. **Preserve original data**: Store snapshot in `original_data` when creating ReviewDecision
5. **Use proper date formatting**: `DateTime.to_iso8601/1` and `Date.to_iso8601/1` for display
6. **Handle nested map fields** in forms using standalone inputs with `name` attributes
