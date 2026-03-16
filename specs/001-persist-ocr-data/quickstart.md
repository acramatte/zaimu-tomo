# Quickstart Guide: Extracted Content Persistence

**Feature**: 001-persist-ocr-data  
**Date**: 2024-07-26  
**Status**: Final

## Overview

This guide provides step-by-step instructions for setting up and using the Extracted Content Persistence feature in the Zaimu Tomo application.

## Prerequisites

Before starting, ensure you have:

- **Elixir 1.15+** installed
- **PostgreSQL 12+** running
- **Phoenix Framework 1.8+** dependencies
- Existing Zaimu Tomo application set up
- Access to the codebase

## Setup

### 1. Create Database Migration

```bash
# Generate the migration file
mix ecto.gen.migration create_extracted_content_table
```

Edit the generated migration file at `priv/repo/migrations/[timestamp]_create_extracted_content_table.exs`:

```elixir
defmodule ZaimuTomo.Repo.Migrations.CreateExtractedContentTable do
  use Ecto.Migration

  def change do
    create table(:extracted_content) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :ocr_content, :map, null: false
      add :llm_content, :map, null: false
      add :confidence_score, :float, null: false
      add :status, :string, null: false
      add :error_details, :map
      add :ocr_version, :string, null: false
      add :llm_version, :string, null: false
      add :processing_duration_ms, :integer, null: false
      add :extraction_timestamp, :naive_datetime, null: false

      timestamps()
    end

    create index(:extracted_content, [:document_id])
    create index(:extracted_content, [:status])
    create index(:extracted_content, [:extraction_timestamp])
    create index(:extracted_content, [:document_id, :extraction_timestamp])
  end
end
```

### 2. Run the Migration

```bash
# Run database migrations
mix ecto.migrate
```

### 3. Create the ExtractedContent Context

Create a new file at `lib/zaimu_tomo/document_processing/extracted_content.ex`:

```elixir
defmodule ZaimuTomo.DocumentProcessing.ExtractedContent do
  @moduledoc """
  Context for managing extracted content from OCR/LLM processing.
  """

  alias ZaimuTomo.Repo
  alias ZaimuTomo.DocumentProcessing.ExtractedContent
  alias ZaimuTomo.Documents.Document

  @doc """
  Creates a new extracted content record.

  ## Parameters
    - attrs: Map containing extracted content data

  ## Returns
    - {:ok, %ExtractedContent{}} on success
    - {:error, changeset} on validation error
  """
  def create_extracted_content(attrs) do
    %ExtractedContent{}
    |> ExtractedContent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieves extracted content by document ID.

  ## Parameters
    - document_id: ID of the document
    - limit: Maximum number of results (default: 50)

  ## Returns
    - List of extracted content records
  """
  def get_by_document(document_id, limit \\ 50) do
    query = from ec in ExtractedContent,
            where: ec.document_id == ^document_id,
            order_by: [desc: :extraction_timestamp],
            limit: ^limit

    Repo.all(query)
  end

  @doc """
  Gets the latest extraction for a document.

  ## Parameters
    - document_id: ID of the document

  ## Returns
    - %ExtractedContent{} or nil
  """
  def get_latest_by_document(document_id) do
    query = from ec in ExtractedContent,
            where: ec.document_id == ^document_id,
            order_by: [desc: :extraction_timestamp],
            limit: 1

    Repo.one(query)
  end

  @doc """
  Lists extracted content with optional filters.

  ## Parameters
    - filters: Map of filter parameters
      - status: Filter by status
      - start_date: Start date filter
      - end_date: End date filter
      - min_confidence: Minimum confidence score
      - limit: Maximum results (default: 50)

  ## Returns
    - Tuple with results and metadata
  """
  def list_extracted_content(filters \\ %{}) do
    query = from ec in ExtractedContent

    query = apply_filters(query, filters)

    limit = Keyword.get(filters, :limit, 50)
    query = order_by(query, [desc: :extraction_timestamp])
    query = limit(query, ^limit)

    results = Repo.all(query)
    total_count = from ec in ExtractedContent, select: count(ec.id) |> Repo.one()

    {results, %{total_count: total_count, limit: limit}}
  end

  @doc """
  Retries a failed extraction.

  ## Parameters
    - extraction_id: ID of the failed extraction
    - max_attempts: Maximum retry attempts (default: 3)

  ## Returns
    - {:ok, retry_info} or {:error, reason}
  """
  def retry_extraction(extraction_id, max_attempts \\ 3) do
    # Implementation would integrate with OCR worker
    # This is a placeholder for the retry logic
    {:ok, %{status: "retry_scheduled", extraction_id: extraction_id}}
  end

  defp apply_filters(query, filters) do
    query
    |> maybe_filter_status(filters)
    |> maybe_filter_date_range(filters)
    |> maybe_filter_confidence(filters)
  end

  defp maybe_filter_status(query, filters) do
    if status = filters[:status] do
      where(query, [ec], ec.status == ^status)
    else
      query
    end
  end

  defp maybe_filter_date_range(query, filters) do
    if start_date = filters[:start_date] || end_date = filters[:end_date] do
      start_date = start_date || DateTime.utc_now() |> DateTime.to_naive() |> DateTime.shift(<<"1970-01-01>>, years: -100)
      end_date = end_date || DateTime.utc_now() |> DateTime.to_naive()

      where(query, [ec],
        ec.extraction_timestamp >= ^start_date and
        ec.extraction_timestamp <= ^end_date
      )
    else
      query
    end
  end

  defp maybe_filter_confidence(query, filters) do
    if min_confidence = filters[:min_confidence] do
      where(query, [ec], ec.confidence_score >= ^min_confidence)
    else
      query
    end
  end
end
```

### 4. Create the ExtractedContent Schema

Create a new file at `lib/zaimu_tomo/document_processing/extracted_content/extracted_content.ex`:

```elixir
defmodule ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent do
  use Ecto.Schema
  import Ecto.Changeset

  alias ZaimuTomo.Documents.Document

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

    belongs_to :document, Document, foreign_key: :document_id, type: :binary_id

    timestamps()
  end

  def changeset(extracted_content, attrs) do
    extracted_content
    |> cast(attrs, [
      :document_id,
      :ocr_content,
      :llm_content,
      :confidence_score,
      :status,
      :error_details,
      :ocr_version,
      :llm_version,
      :processing_duration_ms,
      :extraction_timestamp
    ])
    |> validate_required([
      :document_id,
      :ocr_content,
      :llm_content,
      :status,
      :ocr_version,
      :llm_version,
      :processing_duration_ms
    ])
    |> validate_inclusion(:status, ["success", "partial", "failed"])
    |> validate_number(:confidence_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_content_size(:ocr_content)
    |> validate_content_size(:llm_content)
    |> foreign_key_constraint(:document_id)
  end

  defp validate_content_size(changeset, field) do
    content = get_field(changeset, field)

    case content do
      nil -> changeset
      _ ->
        size = byte_size(Jason.encode!(content))
        if size <= 10_000_000 do
          changeset
        else
          max_size = byte_size("10 MB")
          add_error(changeset, field, "exceeds maximum size of #{max_size} bytes")
        end
    end
  end
end
```

### 5. Add to Document Context

Update `lib/zaimu_tomo/documents.ex` to add the relationship:

```elixir
# Add to the Document schema
defmodule ZaimuTomo.Documents.Document do
  use Ecto.Schema
  # ... existing code ...

  schema "documents" do
    # ... existing fields ...

    has_many :extracted_content, ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

    timestamps()
  end
  # ... rest of existing code ...
end
```

### 6. Create API Controller

Create a new file at `lib/zaimu_tomo_web/controllers/extracted_content_controller.ex`:

```elixir
defmodule ZaimuTomoWeb.ExtractedContentController do
  use ZaimuTomoWeb, :controller

  alias ZaimuTomo.DocumentProcessing.ExtractedContent

  action_fallback ZaimuTomoWeb.FallbackController

  @doc """
  Gets extracted content for a document
  """
  def index(conn, %{"document_id" => document_id}) do
    extractions = ExtractedContent.get_by_document(document_id)
    render(conn, :index, extractions: extractions)
  end

  @doc """
  Gets the latest extraction for a document
  """
  def show(conn, %{"document_id" => document_id}) do
    extraction = ExtractedContent.get_latest_by_document(document_id)

    case extraction do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(ZaimuTomoWeb.ErrorView, "404.json", %{
          message: "No extracted content found for document #{document_id}"
        })
      
      _ ->
        render(conn, :show, extraction: extraction)
    end
  end

  @doc """
  Lists extracted content with filters
  """
  def list(conn, params) do
    {extractions, meta} = ExtractedContent.list_extracted_content(params)
    render(conn, :list, extractions: extractions, meta: meta)
  end

  @doc """
  Retries a failed extraction
  """
  def retry(conn, %{"id" => id}, params) do
    max_attempts = params["max_attempts"] || 3

    case ExtractedContent.retry_extraction(id, max_attempts) do
      {:ok, result} ->
        conn
        |> put_status(:accepted)
        |> render(:retry, result: result)
      
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(ZaimuTomoWeb.ErrorView, "422.json", %{
          message: "Cannot retry extraction",
          details: reason
        })
    end
  end
end
```

### 7. Add Routes

Update `lib/zaimu_tomo_web/router.ex` to add the new routes:

```elixir
# In the :api scope, add:
scope "/api", ZaimuTomoWeb do
  pipe_through :api

  # ... existing routes ...

  resources "/extracted_content", ExtractedContentController, only: [:index, :show] do
    get "/latest", ExtractedContentController, :show
    post "/:id/retry", ExtractedContentController, :retry
  end
end
```

### 8. Create Views

Create a new file at `lib/zaimu_tomo_web/controllers/extracted_content_json.ex`:

```elixir
defmodule ZaimuTomoWeb.ExtractedContentJSON do
  @moduledoc """
  JSON view for extracted content.
  """

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

  def render("index.json", %{extractions: extractions}) do
    %{data: render_many(extractions, ExtractedContentView, "extraction.json")}
  end

  def render("show.json", %{extraction: extraction}) do
    %{data: render_one(extraction, ExtractedContentView, "extraction.json")}
  end

  def render("list.json", %{extractions: extractions, meta: meta}) do
    %{data: render_many(extractions, ExtractedContentView, "extraction.json"), meta: meta}
  end

  def render("retry.json", %{result: result}) do
    %{data: result}
  end
end
```

Create a new file at `lib/zaimu_tomo_web/views/extracted_content_view.ex`:

```elixir
defmodule ZaimuTomoWeb.ExtractedContentView do
  use ZaimuTomoWeb, :view

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent

  def render("extraction.json", %{extraction: %ExtractedContent{} = extraction}) do
    %{
      id: extraction.id,
      document_id: extraction.document_id,
      status: extraction.status,
      confidence_score: extraction.confidence_score,
      ocr_version: extraction.ocr_version,
      llm_version: extraction.llm_version,
      processing_duration_ms: extraction.processing_duration_ms,
      extraction_timestamp: extraction.extraction_timestamp,
      created_at: extraction.inserted_at,
      updated_at: extraction.updated_at,
      ocr_content: extraction.ocr_content,
      llm_content: extraction.llm_content,
      error_details: extraction.error_details
    }
  end
end
```

## Integration with OCR Pipeline

### 1. Update OCR Worker

Modify the OCR worker to persist extraction results. Update `lib/zaimu_tomo/document_processing/ocr_worker.ex`:

```elixir
defmodule ZaimuTomo.DocumentProcessing.OCRWorker do
  # ... existing code ...

  defp persist_extraction_result(%{document_id: doc_id} = result) do
    extraction_params = %{
      document_id: doc_id,
      ocr_content: result.ocr_content,
      llm_content: result.llm_content,
      confidence_score: result.confidence_score,
      status: "success",
      ocr_version: "v2.1.0",  # Get from config
      llm_version: "mistral-small-2.0",  # Get from config
      processing_duration_ms: result.processing_time,
      extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
    }

    case ExtractedContent.create_extracted_content(extraction_params) do
      {:ok, content} ->
        {:ok, content}
      
      {:error, changeset} ->
        # Log error and continue
        {:error, changeset}
    end
  end

  defp handle_processing_result({:ok, result}, _scope) do
    case persist_extraction_result(result) do
      {:ok, content} ->
        # Emit success event
        {:ok, content}
      
      {:error, changeset} ->
        # Handle persistence error
        {:error, changeset}
    end
  end

  defp handle_processing_result({:error, reason}, scope) do
    # Store error information
    error_params = %{
      document_id: scope.document_id,
      status: "failed",
      error_details: %{
        type: "processing_error",
        message: reason.message,
        stack_trace: reason.stack_trace
      },
      ocr_version: "v2.1.0",
      llm_version: "mistral-small-2.0",
      processing_duration_ms: reason.processing_time,
      extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
    }

    ExtractedContent.create_extracted_content(error_params)
    {:error, reason}
  end

  # ... rest of existing code ...
end
```

### 2. Update Event Emission

Ensure events are emitted only after successful persistence. Update the event emission code:

```elixir
defp emit_extraction_event(:success, %{document_id: doc_id, extraction_id: ext_id}) do
  ZaimuTomo.PubSub.emit("document_processing:success", %{
    document_id: doc_id,
    extraction_id: ext_id,
    timestamp: DateTime.utc_now(),
    status: "success"
  })
end

defp emit_extraction_event(:failed, %{document_id: doc_id, error: reason}) do
  ZaimuTomo.PubSub.emit("document_processing:failed", %{
    document_id: doc_id,
    timestamp: DateTime.utc_now(),
    status: "failed",
    error_type: reason.type,
    error_message: reason.message
  })
end
```

## Testing

### 1. Run Tests

```bash
# Run the extracted content tests
mix test test/zaimu_tomo/document_processing/extracted_content_test.exs

# Run all tests
mix test
```

### 2. Create Test File

Create a new test file at `test/zaimu_tomo/document_processing/extracted_content_test.exs`:

```elixir
defmodule ZaimuTomo.DocumentProcessing.ExtractedContentTest do
  use ZaimuTomo.DataCase, async: true

  alias ZaimuTomo.DocumentProcessing.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document

  describe "create_extracted_content/1" do
    test "creates extracted content with valid attributes" do
      document = fixture(:document)

      attrs = %{
        document_id: document.id,
        ocr_content: %{"text" => "Sample content"},
        llm_content: %{"entities" => []},
        confidence_score: 0.95,
        status: "success",
        ocr_version: "v2.1.0",
        llm_version: "mistral-small-2.0",
        processing_duration_ms: 1000,
        extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
      }

      assert {:ok, %ExtractedContent{} = content} = ExtractedContent.create_extracted_content(attrs)
      assert content.document_id == document.id
      assert content.status == "success"
    end

    test "rejects invalid status" do
      document = fixture(:document)

      attrs = %{
        document_id: document.id,
        ocr_content: %{"text" => "Sample"},
        llm_content: %{"entities" => []},
        confidence_score: 0.8,
        status: "invalid_status",
        ocr_version: "v2.1.0",
        llm_version: "mistral-small-2.0",
        processing_duration_ms: 1000,
        extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
      }

      assert {:error, changeset} = ExtractedContent.create_extracted_content(attrs)
      assert changeset.errors[:status] == {"is invalid"}
    end
  end

  describe "get_by_document/1" do
    test "retrieves extracted content for a document" do
      document = fixture(:document)
      content = extracted_content_fixture(document)

      results = ExtractedContent.get_by_document(document.id)
      assert length(results) == 1
      assert hd(results).id == content.id
    end
  end

  describe "get_latest_by_document/1" do
    test "gets the latest extraction for a document" do
      document = fixture(:document)
      old_content = extracted_content_fixture(document, %{
        extraction_timestamp: DateTime.utc_now() |> DateTime.shift(days: -1) |> DateTime.to_naive()
      })
      new_content = extracted_content_fixture(document)

      latest = ExtractedContent.get_latest_by_document(document.id)
      assert latest.id == new_content.id
    end
  end

  describe "list_extracted_content/1" do
    test "lists extracted content with filters" do
      success_content = extracted_content_fixture(fixture(:document), %{status: "success"})
      failed_content = extracted_content_fixture(fixture(:document), %{status: "failed"})

      {results, meta} = ExtractedContent.list_extracted_content(%{status: "success"})
      assert length(results) == 1
      assert hd(results).id == success_content.id
      assert meta[:total_count] >= 1
    end
  end

  defp extracted_content_fixture(document, overrides \\ %{}) do
    attrs = %{
      document_id: document.id,
      ocr_content: %{"text" => "Test content"},
      llm_content: %{"entities" => []},
      confidence_score: 0.9,
      status: "success",
      ocr_version: "v2.1.0",
      llm_version: "mistral-small-2.0",
      processing_duration_ms: 1000,
      extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
    } |> Map.merge(overrides)

    {:ok, content} = ExtractedContent.create_extracted_content(attrs)
    content
  end
end
```

## Deployment

### 1. Run Migrations

```bash
# In production environment
MIX_ENV=prod mix ecto.migrate
```

### 2. Restart Application

```bash
# Restart the Phoenix server
sudo systemctl restart zaimu_tomo
```

### 3. Verify Deployment

```bash
# Check application health
curl -X GET https://api.zaimu-tomo.com/api/health

# Test the new endpoint
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/1 \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

## Monitoring

### 1. Set Up Monitoring

Add monitoring for the new endpoints:

```elixir
# In your telemetry configuration
config :telemetry, :default, 
  metrics: [
    # ... existing metrics ...
    {"zaimu_tomo.extracted_content.create", %{
      description: "Extracted content creation",
      tags: [:status]
    }},
    {"zaimu_tomo.extracted_content.retrieve", %{
      description: "Extracted content retrieval",
      tags: [:document_id]
    }}
  ]
```

### 2. Add Logging

Enhance logging for the new feature:

```elixir
# In your logger configuration
config :logger, :console,
  format: "[$level] $message $metadata",
  metadata: [:request_id, :user_id]

# Add context to your controller
def index(conn, params) do
  Logger.info("Retrieving extracted content", 
    request_id: conn.assigns[:request_id],
    document_id: params["document_id"]
  )
  # ... rest of controller code
end
```

## Troubleshooting

### Common Issues

**1. Migration Fails**
- **Check**: Database connection and permissions
- **Fix**: Verify PostgreSQL is running and credentials are correct

**2. API Returns 404**
- **Check**: Route configuration and controller existence
- **Fix**: Verify routes are properly added to router.ex

**3. Validation Errors**
- **Check**: Input data format and required fields
- **Fix**: Ensure all required fields are provided in correct format

**4. Performance Issues**
- **Check**: Database indexes and query optimization
- **Fix**: Add missing indexes or optimize queries

### Debugging Commands

```bash
# Check database connection
mix ecto.psql

# Run specific tests
mix test test/zaimu_tomo/document_processing/extracted_content_test.exs

# Check compilation
mix compile

# View logs
tail -f log/prod.log
```

## Best Practices

### 1. Error Handling

```elixir
# Wrap database operations in try/rescue
try do
  ExtractedContent.create_extracted_content(attrs)
rescue
  e in Ecto.ConstraintError ->
    Logger.error("Constraint error: #{e.message}")
    {:error, "Database constraint violated"}
end
```

### 2. Input Validation

```elixir
# Validate input before processing
def create_extracted_content(conn, params) do
  with {:ok, _} <- validate_params(params),
       {:ok, content} <- ExtractedContent.create_extracted_content(params) do
    render(conn, :show, extraction: content)
  else
    {:error, changeset} ->
      render(conn, :error, changeset: changeset)
  end
end
```

### 3. Performance Optimization

```elixir
# Use selective loading for large datasets
def get_by_document(document_id) do
  query = from ec in ExtractedContent,
          where: ec.document_id == ^document_id,
          order_by: [desc: :extraction_timestamp],
          limit: 50,
          select: %{
            id: ec.id,
            status: ec.status,
            confidence_score: ec.confidence_score,
            extraction_timestamp: ec.extraction_timestamp
          }

  Repo.all(query)
end
```

### 4. Security

```elixir
# Always validate document ownership
def get_by_document(conn, %{"document_id" => doc_id}) do
  if Documents.user_owns_document?(conn.assigns[:current_user], doc_id) do
    # Proceed with retrieval
  else
    conn |> put_status(:forbidden) |> halt()
  end
end
```

## Example Usage

### 1. Creating Extracted Content

```elixir
# In your OCR processing pipeline
attrs = %{
  document_id: document.id,
  ocr_content: ocr_results,
  llm_content: llm_results,
  confidence_score: 0.95,
  status: "success",
  ocr_version: "v2.1.0",
  llm_version: "mistral-small-2.0",
  processing_duration_ms: 1250,
  extraction_timestamp: DateTime.utc_now() |> DateTime.to_naive()
}

case ExtractedContent.create_extracted_content(attrs) do
  {:ok, content} ->
    # Success - emit event
    {:ok, content}
  
  {:error, changeset} ->
    # Handle error
    {:error, changeset}
end
```

### 2. Retrieving Extracted Content

```elixir
# Get all extractions for a document
extractions = ExtractedContent.get_by_document(document_id)

# Get the latest extraction
latest = ExtractedContent.get_latest_by_document(document_id)

# List with filters
{results, meta} = ExtractedContent.list_extracted_content(%{
  status: "success",
  start_date: "2024-01-01",
  min_confidence: 0.9
})
```

### 3. Using the API

```bash
# Get extracted content for document 42
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/42 \
  -H 'Authorization: Bearer YOUR_TOKEN'

# Get latest extraction
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/42/latest \
  -H 'Authorization: Bearer YOUR_TOKEN'

# List successful extractions
curl -X GET \
  'https://api.zaimu-tomo.com/api/extracted_content?status=success' \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

## Migration Guide

### From No Persistence to Persistence

**Before**: Extracted content was processed but not stored
**After**: Extracted content is persistently stored and retrievable

**Migration Steps**:

1. **Deploy the new code** with persistence functionality
2. **Process existing documents** through the updated pipeline to populate historical data
3. **Update clients** to use the new API endpoints
4. **Monitor performance** and adjust as needed

**Backward Compatibility**:
- Existing OCR processing continues to work
- New persistence is additive
- No breaking changes to existing functionality

## Performance Tuning

### 1. Database Optimization

```sql
-- Add indexes for common queries
CREATE INDEX IF NOT EXISTS extracted_content_document_status_idx 
ON extracted_content(document_id, status);

-- Analyze tables for query planner
ANALYZE extracted_content;
```

### 2. Query Optimization

```elixir
# Optimize common queries
def get_recent_successful(document_id, limit \\ 10) do
  query = from ec in ExtractedContent,
          where: ec.document_id == ^document_id,
          where: ec.status == "success",
          order_by: [desc: :extraction_timestamp],
          limit: ^limit,
          select: {ec.id, ec.status, ec.confidence_score, ec.extraction_timestamp}

  Repo.all(query)
end
```

### 3. Caching Strategy

```elixir
# Implement caching for frequent queries
def get_by_document_cached(document_id) do
  cache_key = "extracted_content:#{document_id}"

  case Cache.get(cache_key) do
    nil ->
      results = get_by_document(document_id)
      Cache.put(cache_key, results, ttl: :timer.hours(1))
      results
    
    cached ->
      cached
  end
end
```

## Security Considerations

### 1. Data Protection

```elixir
# Encrypt sensitive data
defp encrypt_sensitive_data(content) do
  # Implement encryption for sensitive fields
  content
end
```

### 2. Access Control

```elixir
# Implement fine-grained access control
def can_access_extracted_content?(user, document_id) do
  # Check document ownership and permissions
  Documents.user_owns_document?(user, document_id)
end
```

### 3. Audit Logging

```elixir
# Log sensitive operations
def get_by_document(conn, params) do
  Logger.info("Accessing extracted content", 
    user_id: conn.assigns[:current_user].id,
    document_id: params["document_id"],
    ip_address: conn.remote_ip
  )
  # ... rest of function
end
```

## Scaling

### 1. Horizontal Scaling

```elixir
# Configure connection pooling for scalability
config :zaimu_tomo, ZaimuTomo.Repo,
  pool_size: 20,
  timeout: 15_000
```

### 2. Read Replicas

```elixir
# Configure read replicas for query load
config :zaimu_tomo, ZaimuTomo.Repo,
  read_replica: System.get_env("DATABASE_READ_REPLICA")
```

### 3. Load Balancing

```nginx
# Nginx configuration for load balancing
upstream api_servers {
  server api1.zaimu-tomo.com;
  server api2.zaimu-tomo.com;
  server api3.zaimu-tomo.com;
}

server {
  listen 443 ssl;
  server_name api.zaimu-tomo.com;

  location /api/extracted_content {
    proxy_pass http://api_servers;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
```

## Monitoring and Alerts

### 1. Key Metrics to Monitor

```elixir
# Track important metrics
:telemetry.execute([:zaimu_tomo, :extracted_content, :create], %{
  status: status,
  duration: System.monotonic_time() - start_time
})
```

### 2. Alert Configuration

```yaml
# Example Prometheus alert rules
- alert: HighExtractionFailureRate
  expr: rate(extracted_content_failures_total[5m]) / rate(extracted_content_requests_total[5m]) > 0.1
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "High extraction failure rate"
    description: "Extraction failure rate is {{ $value }}%"
```

### 3. Dashboard Setup

Create a dashboard with:
- Request volume and response times
- Error rates and types
- Database query performance
- Cache hit rates
- Resource utilization

## Documentation

### 1. API Documentation

Update your API documentation:

```markdown
# Extracted Content API

## Endpoints

### GET /api/extracted_content/{document_id}
Retrieves extracted content for a document

**Parameters**:
- `document_id`: Document identifier

**Response**:
```json
{
  "data": [
    {
      "id": 1,
      "document_id": 42,
      "status": "success",
      "confidence_score": 0.95,
      "ocr_content": {...},
      "llm_content": {...}
    }
  ]
}
```
```

### 2. Developer Guide

Create a developer guide covering:
- Architecture overview
- Integration points
- Common patterns
- Troubleshooting
- Best practices

### 3. User Documentation

Update user documentation with:
- Feature overview
- Use cases
- Example workflows
- Limitations
- FAQ

## Support and Maintenance

### 1. Support Channels

- **Email**: support@zaimu-tomo.com
- **Slack**: #extracted-content channel
- **GitHub Issues**: zaimu-tomo/extracted-content

### 2. Maintenance Schedule

- **Patch releases**: As needed for critical fixes
- **Minor releases**: Monthly with new features
- **Major releases**: Quarterly with breaking changes

### 3. Deprecation Policy

- **Announcement**: 6 months before deprecation
- **Documentation**: Migration guides provided
- **Support**: Extended support during transition

## Conclusion

This quickstart guide provides everything needed to implement the Extracted Content Persistence feature in the Zaimu Tomo application. The implementation:

✅ **Follows best practices** for Elixir/Phoenix development
✅ **Integrates seamlessly** with existing architecture
✅ **Provides comprehensive** API and database functionality
✅ **Includes thorough** testing and documentation
✅ **Supports future** scalability and enhancements

The feature is now ready for deployment and will provide persistent storage for OCR/LLM extraction results, enabling historical analysis and improved data retention.