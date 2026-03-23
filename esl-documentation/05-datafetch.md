# DataFetch API

## Purpose

The DataFetch API is a read-only REST service that exposes ESL data stored in PostgreSQL to downstream consumers. It provides paginated access to stores, products, labels, and access points with field-level search capabilities.

The API is designed for secure, high-performance data retrieval — all queries use parameterised SQL, input is strictly validated, and the service includes built-in observability via Prometheus metrics and structured logging.

## Technology Stack

| Technology | Version | Purpose |
|---|---|---|
| Go | 1.26+ | Application language |
| Gin | 1.11 | HTTP framework |
| pgx/v5 | — | PostgreSQL driver with connection pooling |
| Zap | 1.27 | Structured logging |
| Prometheus client | 1.23 | Metrics instrumentation |
| Swagger UI | — | Embedded interactive API documentation |

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/{entity_name}` | Fetch entity data with pagination and search |
| `GET` | `/health` | Service health check (always 200) |
| `GET` | `/ready` | Readiness check (includes DB connectivity) |
| `GET` | `/metrics` | Prometheus metrics |
| `GET` | `/openapi.yaml` | OpenAPI 3.0 specification |
| `GET` | `/swagger` | Interactive Swagger UI |

### POST /v1/{entity_name}

The main data retrieval endpoint. Returns rows from the specified entity with optional pagination and search filters.

**Path parameter:**

- `entity_name` — one of: `stores`, `products`, `labels`, `access_points`

**Request body** (JSON, all fields optional):

```json
{
  "page": 1,
  "pageSize": 10,
  "search": "store_id:bomdia_pt.009648"
}
```

| Field | Type | Default | Constraints |
|---|---|---|---|
| `page` | integer | 1 | >= 1 |
| `pageSize` | integer | 10 | 1–100 |
| `search` | string | (empty) | Max 1000 characters |

**Response** (200 OK):

```json
{
  "entityName": "stores",
  "page": 1,
  "pageSize": 10,
  "totalCount": 1523,
  "rows": [
    {
      "retail_chain_id": "continente_pt",
      "store_id": "001234",
      "store_name": "Continente Matosinhos",
      ...
    }
  ]
}
```

**Error responses:**

| Status | Code | Scenario |
|---|---|---|
| 400 | `INVALID_INPUT` | Bad request body, unknown field in search, invalid search syntax |
| 404 | `NOT_FOUND` | Entity name does not exist |
| 413 | `INVALID_INPUT` | Request body exceeds 64 KB |
| 500 | `DATABASE_ERROR` | Query execution failure |
| 504 | `TIMEOUT` | Query exceeded timeout |

### Health and Readiness

- `GET /health` — returns `{"status": "ok", "service": "datafetch"}` (always 200)
- `GET /ready` — returns `{"status": "ready", "checks": {"database": "ok"}}` or 503 if the database is unreachable (2-second ping timeout)

## Search Syntax

The `search` field supports field-level filtering with three operators:

### Equality

```
field:value
```

Example: `status:active`

### OR

```
field1:value1 OR field2:value2
```

Example: `store_id:bomdia_pt.009648 OR store_id:continente_pt.000001`

### AND

```
field1:value1 AND field2:value2
```

Example: `status:active AND custom_dept:grocery`

> **Note:** AND and OR cannot be mixed in a single search expression.

### Timestamp Range

For timestamp columns only:

```
field:[lower_bound TO upper_bound]
```

Bounds must be RFC 3339 timestamps or `*` (unbounded). At least one bound is required.

Examples:

- `creation_date:[2024-01-01T00:00:00Z TO 2024-12-31T23:59:59Z]` — closed range
- `creation_date:[* TO 2024-06-01T00:00:00Z]` — open lower bound
- `modification_date:[2024-01-01T00:00:00Z TO *]` — open upper bound

### Type Validation

Search values are validated against the column type before query execution:

| Column Type | Accepted Values |
|---|---|
| text | Any string |
| integer | 64-bit signed integer |
| numeric | Floating-point number |
| boolean | `true`, `false`, `1`, `0` |
| timestamp | RFC 3339 format |
| array | Text value (matched via PostgreSQL `@>` contains operator) |

### Constraints

- Max search string length: 1000 characters
- Max individual term length: 255 characters
- Max field name length: 64 characters
- Field names: alphanumeric and underscores only

## Entity Registry

Entities are defined in an embedded YAML configuration (`entities.yaml`) that specifies which database tables are queryable, their columns, types, and primary keys. At startup, the registry is validated against the live database schema — if a declared column does not exist in the database, the service will not start.

### Available Entities

| Entity | Table | Primary Key | Columns (API-visible) |
|---|---|---|---|
| `stores` | `esl.stores` | `retail_chain_id, store_id` | 19 |
| `products` | `esl.products` | `retail_chain_id, store_id, item_id` | 66 |
| `labels` | `esl.labels` | `store_id, retail_chain_id, label_id` | 39 |
| `access_points` | `esl.access_points` | `retail_chain_id, store_id, id` | 13 |

Internal columns (`created_at`, `last_updated_at`) are excluded from API responses and are not searchable.

Results are ordered deterministically by primary key columns.

## Security

### SQL Injection Prevention

- All user input is passed as parameterised values (`$1`, `$2`, etc.) — never concatenated into SQL strings
- Entity and column names are sanitised via `pgx.Identifier{}.Sanitize()`
- Field names in search are validated against a strict regex (`^[a-zA-Z0-9_]+$`) and must exist in the entity registry

### Input Validation

| Input | Limit |
|---|---|
| Request body size | 64 KB |
| Page size | 100 rows |
| Search string | 1000 characters |
| Individual search term | 255 characters |
| Field name | 64 characters |
| Request ID header | 128 characters, alphanumeric + `.` `-` `_` |

Unknown JSON fields in the request body are rejected.

### Security Headers

All responses include the following headers:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: geolocation=(), microphone=(), camera=()`
- `Content-Security-Policy` (configured for Swagger UI compatibility)

### Container Security

The service runs as a non-root user (UID 1002) in a distroless container with a read-only root filesystem and all Linux capabilities dropped.

## Configuration

The service is configured via environment variables with defaults that vary by environment.

### Core Settings

| Variable | Dev Default | Prod Default | Description |
|---|---|---|---|
| `APP_ENV` | development | — | Environment profile |
| `HTTP_PORT` | 8080 | 8080 | Server port |
| `LOG_LEVEL` | info | info | debug, info, warn, error |

### Database Connection

| Variable | Dev Default | Prod Default | Description |
|---|---|---|---|
| `DB_HOST` | localhost | localhost | PostgreSQL host |
| `DB_PORT` | 5432 | 5432 | PostgreSQL port |
| `DB_USER` | postgres | postgres | Database user |
| `DB_PASSWORD` | postgres | postgres | Database password |
| `DB_NAME` | datafetch | datafetch | Database name |
| `DB_SCHEMA` | public | public | Schema for entity tables |
| `DB_SSL_MODE` | disable | require | SSL mode |

### Connection Pool

| Variable | Dev Default | Prod Default | Description |
|---|---|---|---|
| `DB_MAX_CONNS` | 10 | 25 | Maximum connections |
| `DB_MIN_CONNS` | 2 | 5 | Minimum idle connections |
| `DB_MAX_CONN_LIFETIME` | 30 | 60 | Connection max lifetime (minutes) |
| `DB_MAX_CONN_IDLE_TIME` | 15 | 30 | Idle timeout (minutes) |
| `DB_HEALTH_CHECK_PERIOD` | 30 | 60 | Health check interval (seconds) |

### Timeouts

| Variable | Dev Default | Prod Default | Description |
|---|---|---|---|
| `QUERY_TIMEOUT` | 15 | 30 | Database query timeout (seconds) |
| `HTTP_READ_TIMEOUT` | 30 | 30 | HTTP read timeout (seconds) |
| `HTTP_WRITE_TIMEOUT` | 60 | 60 | HTTP write timeout (seconds) |

## Observability

### Prometheus Metrics

Available at `GET /metrics`.

**HTTP metrics:**

| Metric | Type | Labels | Description |
|---|---|---|---|
| `http_requests_total` | Counter | method, path, status | Total request count |
| `http_request_duration_seconds` | Histogram | method, path | Request latency |
| `http_requests_in_flight` | Gauge | — | Current concurrent requests |

**Database metrics:**

| Metric | Type | Labels | Description |
|---|---|---|---|
| `database_queries_total` | Counter | table, operation | Total query count |
| `database_query_duration_seconds` | Histogram | operation | Query latency |
| `database_connection_pool_size` | Gauge | state | Pool usage (acquired, idle, total) |

Connection pool stats are collected every 15 seconds.

### Structured Logging

All log entries include `request_id`, `method`, `path`, `status`, and `latency`. Errors include additional context (entity name, search string, error code). Logs are JSON in production and human-readable in development.

### Request Tracing

Every request is tagged with a request ID via the `X-Request-ID` header. If not provided by the client, the server generates a UUID v4. The ID is echoed in the response and included in all log entries for correlation.
