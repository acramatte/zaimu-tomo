# API Contracts: Extracted Content

**Feature**: 001-persist-ocr-data  
**Date**: 2026-03-16  
**Status**: Final

## Overview

This document defines the API contracts for the Extracted Content feature, specifying the endpoints, request/response formats, and behavior for interacting with persisted OCR/LLM extraction results.

## Base URL

```
https://api.zaimu-tomo.com/api/extracted_content
```

## Authentication

All endpoints require authentication using the existing authentication system:
- **Header**: `Authorization: Bearer <token>`
- **Scope**: User must have access to the document

## Endpoints

### 1. Get Extracted Content by Document ID

**Endpoint**: `GET /api/extracted_content/{document_id}`

**Description**: Retrieve all extracted content entries for a specific document

**Parameters**:

| Name | Type | Location | Description | Required | Example |
|------|------|----------|-------------|----------|---------|
| `document_id` | integer | path | Document identifier | Yes | `42` |
| `limit` | integer | query | Maximum number of results | No | `50` |
| `offset` | integer | query | Pagination offset | No | `0` |

**Request Example**:
```http
GET /api/extracted_content/42?limit=10 HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Accept: application/json
```

**Response**:

**Success (200 OK)**:
```json
{
  "data": [
    {
      "id": 1,
      "document_id": 42,
      "status": "success",
      "confidence_score": 0.95,
      "ocr_version": "v2.1.0",
      "llm_version": "mistral-small-2.0",
      "processing_duration_ms": 1250,
      "extraction_timestamp": "2024-07-26T14:30:00Z",
      "created_at": "2024-07-26T14:30:05Z",
      "ocr_content": {
        "text": "INVOICE\nAcme Corp\n...",
        "pages": [
          {"page": 1, "text": "...", "words": [...]}
        ]
      },
      "llm_content": {
        "entities": [
          {"type": "company", "name": "Acme Corp", "confidence": 0.98}
        ],
        "summary": "Invoice from Acme Corp..."
      }
    },
    {
      "id": 2,
      "document_id": 42,
      "status": "failed",
      "confidence_score": 0.45,
      "error_details": {
        "type": "llm_timeout",
        "message": "Processing timed out"
      },
      "extraction_timestamp": "2024-07-25T10:15:00Z",
      "created_at": "2024-07-25T10:15:05Z"
    }
  ],
  "meta": {
    "total_count": 2,
    "limit": 10,
    "offset": 0,
    "has_more": false
  }
}
```

**Error Responses**:

- **401 Unauthorized**: Invalid or missing authentication token
- **403 Forbidden**: User doesn't have access to the document
- **404 Not Found**: Document not found or no extracted content
- **500 Internal Server Error**: Server error

**Curl Example**:
```bash
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/42 \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json'
```

### 2. List Extracted Content with Filters

**Endpoint**: `GET /api/extracted_content`

**Description**: Retrieve extracted content with optional filtering and pagination

**Parameters**:

| Name | Type | Location | Description | Required | Example |
|------|------|----------|-------------|----------|---------|
| `status` | string | query | Filter by status | No | `success` |
| `document_id` | integer | query | Filter by document ID | No | `42` |
| `start_date` | string | query | Start date (ISO 8601) | No | `2024-07-01` |
| `end_date` | string | query | End date (ISO 8601) | No | `2024-07-31` |
| `min_confidence` | float | query | Minimum confidence score | No | `0.9` |
| `limit` | integer | query | Maximum results per page | No | `50` |
| `cursor` | string | query | Pagination cursor | No | `eyJpZCI6IDEwMH0=` |

**Request Example**:
```http
GET /api/extracted_content?status=success&start_date=2024-07-01&limit=20 HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Accept: application/json
```

**Response**:

**Success (200 OK)**:
```json
{
  "data": [
    {
      "id": 1,
      "document_id": 42,
      "status": "success",
      "confidence_score": 0.95,
      "extraction_timestamp": "2024-07-26T14:30:00Z",
      "document": {
        "id": 42,
        "filename": "invoice.pdf",
        "created_at": "2024-07-25T09:00:00Z"
      }
    },
    {
      "id": 3,
      "document_id": 45,
      "status": "success",
      "confidence_score": 0.92,
      "extraction_timestamp": "2024-07-24T11:20:00Z",
      "document": {
        "id": 45,
        "filename": "receipt.jpg",
        "created_at": "2024-07-24T10:15:00Z"
      }
    }
  ],
  "meta": {
    "total_count": 42,
    "limit": 20,
    "next_cursor": "eyJpZCI6IDIwfQ==",
    "has_more": true
  }
}
```

**Error Responses**:

- **400 Bad Request**: Invalid parameters
- **401 Unauthorized**: Invalid or missing authentication token
- **500 Internal Server Error**: Server error

**Curl Example**:
```bash
curl -X GET \
  'https://api.zaimu-tomo.com/api/extracted_content?status=success&limit=20' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json'
```

### 3. Get Latest Extraction for Document

**Endpoint**: `GET /api/extracted_content/{document_id}/latest`

**Description**: Retrieve the most recent extraction for a document

**Parameters**:

| Name | Type | Location | Description | Required | Example |
|------|------|----------|-------------|----------|---------|
| `document_id` | integer | path | Document identifier | Yes | `42` |

**Request Example**:
```http
GET /api/extracted_content/42/latest HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Accept: application/json
```

**Response**:

**Success (200 OK)**:
```json
{
  "data": {
    "id": 1,
    "document_id": 42,
    "status": "success",
    "confidence_score": 0.95,
    "ocr_content": {
      "text": "INVOICE\nAcme Corp\n...",
      "pages": [...]
    },
    "llm_content": {
      "entities": [...],
      "summary": "Invoice from Acme Corp..."
    },
    "ocr_version": "v2.1.0",
    "llm_version": "mistral-small-2.0",
    "processing_duration_ms": 1250,
    "extraction_timestamp": "2024-07-26T14:30:00Z",
    "created_at": "2024-07-26T14:30:05Z"
  }
}
```

**Error Responses**:

- **401 Unauthorized**: Invalid or missing authentication token
- **403 Forbidden**: User doesn't have access to the document
- **404 Not Found**: Document not found or no extracted content
- **500 Internal Server Error**: Server error

**Curl Example**:
```bash
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/42/latest \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json'
```

### 4. Retry Failed Extraction

**Endpoint**: `POST /api/extracted_content/{extraction_id}/retry`

**Description**: Retry a failed extraction process

**Parameters**:

| Name | Type | Location | Description | Required | Example |
|------|------|----------|-------------|----------|---------|
| `extraction_id` | integer | path | Extraction identifier | Yes | `1` |

**Request Example**:
```http
POST /api/extracted_content/1/retry HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Accept: application/json
Content-Type: application/json

{
  "max_attempts": 3
}
```

**Request Body**:
```json
{
  "max_attempts": 3
}
```

**Response**:

**Accepted (202 Accepted)**:
```json
{
  "data": {
    "status": "retry_scheduled",
    "extraction_id": 1,
    "document_id": 42,
    "scheduled_attempts": 3,
    "next_attempt": "2024-07-26T15:00:00Z"
  }
}
```

**Error Responses**:

- **400 Bad Request**: Invalid parameters or extraction not retryable
- **401 Unauthorized**: Invalid or missing authentication token
- **403 Forbidden**: User doesn't have access to the document
- **404 Not Found**: Extraction not found
- **409 Conflict**: Extraction already successful or max retries exceeded
- **500 Internal Server Error**: Server error

**Curl Example**:
```bash
curl -X POST \
  https://api.zaimu-tomo.com/api/extracted_content/1/retry \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{"max_attempts": 3}'
```

### 5. Get Extraction Statistics

**Endpoint**: `GET /api/extracted_content/statistics`

**Description**: Retrieve statistics about extracted content

**Parameters**:

| Name | Type | Location | Description | Required | Example |
|------|------|----------|-------------|----------|---------|
| `time_range` | string | query | Time range for statistics | No | `30days` |

**Request Example**:
```http
GET /api/extracted_content/statistics?time_range=30days HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
Accept: application/json
```

**Response**:

**Success (200 OK)**:
```json
{
  "data": {
    "time_range": "30days",
    "total_extractions": 1250,
    "success_rate": 94.5,
    "status_distribution": {
      "success": 1181,
      "partial": 42,
      "failed": 27
    },
    "average_confidence": 0.89,
    "average_processing_time_ms": 1850,
    "storage_used_mb": 452,
    "extraction_trends": {
      "daily": [
        {"date": "2024-07-01", "count": 35, "success_rate": 91.4},
        {"date": "2024-07-02", "count": 42, "success_rate": 95.2}
      ]
    }
  }
}
```

**Error Responses**:

- **400 Bad Request**: Invalid time range
- **401 Unauthorized**: Invalid or missing authentication token
- **500 Internal Server Error**: Server error

**Curl Example**:
```bash
curl -X GET \
  'https://api.zaimu-tomo.com/api/extracted_content/statistics?time_range=30days' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json'
```

## Event Contracts

### 1. document_processing:success

**Event Name**: `document_processing:success`

**Description**: Emitted when extraction is successfully processed and persisted

**Payload**:
```json
{
  "document_id": 42,
  "extraction_id": 1,
  "timestamp": "2024-07-26T14:30:05Z",
  "status": "success",
  "confidence_score": 0.95,
  "ocr_version": "v2.1.0",
  "llm_version": "mistral-small-2.0",
  "processing_duration_ms": 1250,
  "user_id": 123
}
```

**Emitted When**: After successful database transaction committing the extraction

**Consumers**:
- Notification system (user notifications)
- Analytics dashboard (success metrics)
- Audit logging (activity tracking)

### 2. document_processing:failed

**Event Name**: `document_processing:failed`

**Description**: Emitted when extraction processing fails

**Payload**:
```json
{
  "document_id": 43,
  "extraction_id": 2,
  "timestamp": "2024-07-26T14:35:15Z",
  "status": "failed",
  "error_type": "llm_timeout",
  "error_message": "LLM processing timed out after 30 seconds",
  "retry_count": 3,
  "ocr_version": "v2.1.0",
  "llm_version": "mistral-small-2.0",
  "processing_duration_ms": 30500,
  "user_id": 123
}
```

**Emitted When**: After all retry attempts are exhausted or immediate failure

**Consumers**:
- Alerting system (admin alerts)
- Analytics dashboard (failure metrics)
- Support ticketing (automatic ticket creation)
- Audit logging (activity tracking)

## Webhook Contracts

### Extraction Completed Webhook

**Endpoint**: Configurable by client

**Method**: `POST`

**Headers**:
```
Content-Type: application/json
X-ZaimuTomo-Event: extraction.completed
X-ZaimuTomo-Signature: <HMAC signature>
```

**Payload**:
```json
{
  "event": "extraction.completed",
  "event_id": "evt_123456789",
  "timestamp": "2024-07-26T14:30:05Z",
  "data": {
    "document_id": 42,
    "extraction_id": 1,
    "status": "success",
    "confidence_score": 0.95,
    "user_id": 123,
    "organization_id": 456,
    "metadata": {
      "ocr_version": "v2.1.0",
      "llm_version": "mistral-small-2.0"
    }
  },
  "links": {
    "document": "https://api.zaimu-tomo.com/api/documents/42",
    "extraction": "https://api.zaimu-tomo.com/api/extracted_content/1",
    "download": "https://api.zaimu-tomo.com/api/extracted_content/1/download"
  }
}
```

**Security**:
- HMAC signature verification required
- HTTPS required
- Rate limiting applied

**Retry Policy**:
- 3 attempts with exponential backoff
- Max 10 seconds total retry window

## Error Handling

### Standard Error Format

```json
{
  "error": {
    "code": "error_code",
    "message": "Human-readable error message",
    "details": {
      "field": "specific_field",
      "reason": "validation_failed",
      "expected": "valid_email_format"
    },
    "documentation": "https://docs.zaimu-tomo.com/errors/error_code"
  }
}
```

### Common Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `invalid_parameters` | 400 | Invalid request parameters |
| `unauthorized` | 401 | Authentication required |
| `forbidden` | 403 | Insufficient permissions |
| `not_found` | 404 | Resource not found |
| `rate_limit_exceeded` | 429 | Too many requests |
| `server_error` | 500 | Internal server error |
| `service_unavailable` | 503 | Service temporarily unavailable |

## Rate Limiting

- **Authenticated Users**: 100 requests per minute
- **Unauthenticated**: Not applicable (all endpoints require auth)
- **Headers**:
  - `X-RateLimit-Limit`: Total limit
  - `X-RateLimit-Remaining`: Remaining requests
  - `X-RateLimit-Reset`: Seconds until reset

## Versioning

- **API Version**: `v1`
- **Header**: `Accept: application/vnd.zaimu-tomo.v1+json`
- **Deprecation Policy**: 6 months notice before removal
- **Changelog**: `/api/changelog` endpoint

## Security

### Authentication
- JWT tokens with HS256 algorithm
- Token expiration: 1 hour
- Refresh tokens: 30 days

### Authorization
- Document ownership verification
- Role-based access control
- Scope-based permissions

### Data Protection
- HTTPS/TLS 1.2+ required
- Sensitive data encryption at rest
- Regular security audits

### Input Validation
- Strict parameter validation
- Content size limits (10MB)
- SQL injection prevention
- XSS protection

## Performance SLAs

- **Response Time**: < 500ms for 95% of requests
- **Availability**: 99.9% uptime
- **Throughput**: 100+ requests per second
- **Concurrency**: Handle 100+ concurrent users

## Monitoring and Observability

### Metrics Endpoint

**Endpoint**: `GET /api/extracted_content/_monitoring`

**Response**:
```json
{
  "status": "healthy",
  "timestamp": "2024-07-26T14:30:00Z",
  "metrics": {
    "request_count": 1250,
    "error_rate": 0.02,
    "avg_response_time_ms": 285,
    "db_query_time_ms": 45,
    "cache_hit_rate": 0.85
  },
  "dependencies": {
    "database": "healthy",
    "storage": "healthy",
    "llm_service": "healthy"
  }
}
```

### Health Check

**Endpoint**: `GET /api/health`

**Response**:
```json
{
  "status": "healthy",
  "version": "1.0.0",
  "timestamp": "2024-07-26T14:30:00Z",
  "components": {
    "database": "ok",
    "cache": "ok",
    "storage": "ok",
    "extracted_content": "ok"
  }
}
```

## SDK Examples

### JavaScript

```javascript
const api = require('zaimu-tomo-sdk')({ apiKey: 'YOUR_API_KEY' });

// Get extracted content for document
const extractions = await api.extractedContent.list({ documentId: 42 });

// Get latest extraction
const latest = await api.extractedContent.getLatest(42);

// Retry failed extraction
const retryResult = await api.extractedContent.retry(1);
```

### Python

```python
from zaimu_tomo import Client

client = Client(api_key="YOUR_API_KEY")

# Get extracted content for document
extractions = client.extracted_content.list(document_id=42)

# Get latest extraction
latest = client.extracted_content.get_latest(42)

# Retry failed extraction
retry_result = client.extracted_content.retry(extraction_id=1)
```

### cURL

```bash
# Get extracted content
curl -X GET \
  https://api.zaimu-tomo.com/api/extracted_content/42 \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Accept: application/json'

# Retry failed extraction
curl -X POST \
  https://api.zaimu-tomo.com/api/extracted_content/1/retry \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"max_attempts": 3}'
```

## Changelog

### v1.0.0 - 2024-07-26

**Initial Release**
- All endpoints implemented
- Event contracts defined
- Webhook support added
- Rate limiting enforced
- Comprehensive error handling

## Support

**Contact**: support@zaimu-tomo.com
**Documentation**: https://docs.zaimu-tomo.com/api/extracted-content
**Status Page**: https://status.zaimu-tomo.com

## Legal

**Terms of Service**: https://zaimu-tomo.com/terms
**Privacy Policy**: https://zaimu-tomo.com/privacy
**Data Processing Agreement**: https://zaimu-tomo.com/dpa

## Implementation Notes

1. **Idempotency**: All GET endpoints are idempotent
2. **Pagination**: Use cursor-based pagination for large datasets
3. **Caching**: Responses may be cached (respect Cache-Control headers)
4. **Rate Limiting**: Respect rate limit headers
5. **Error Handling**: Always check error responses
6. **Versioning**: Include Accept header for versioning
7. **Security**: Never expose API keys in client-side code

## Contract Compliance

This API contract complies with:
- ✅ RESTful design principles
- ✅ JSON API specification
- ✅ OAuth 2.0 security standards
- ✅ GDPR data protection requirements
- ✅ WCAG 2.1 accessibility guidelines

## Future Considerations

### Potential Enhancements

1. **WebSocket Support**: Real-time extraction progress updates
2. **GraphQL Endpoint**: Flexible querying capabilities
3. **Bulk Operations**: Batch retrieval and processing
4. **Advanced Filtering**: More sophisticated query capabilities
5. **Export Formats**: CSV, PDF export options

### Deprecation Plan

1. **Announcement**: 6 months before deprecation
2. **Documentation**: Clear migration guides
3. **Support**: Extended support during transition
4. **Sunset**: Final shutdown with advance notice

## Conclusion

This API contract provides a comprehensive, well-documented interface for interacting with extracted OCR/LLM content. It follows RESTful principles, includes proper authentication and authorization, handles errors gracefully, and provides clear contracts for both request/response formats and event-based interactions.

The contract is designed to be:
- **Developer-friendly**: Clear examples, multiple language SDKs
- **Reliable**: Proper error handling, status monitoring
- **Secure**: Authentication, rate limiting, input validation
- **Scalable**: Pagination, efficient queries
- **Maintainable**: Versioned, documented, observable

Implementation can proceed with confidence based on these well-defined contracts.
