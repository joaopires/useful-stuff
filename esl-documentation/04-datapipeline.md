# Data Pipeline

## Purpose

The Data Pipeline is the ingestion engine of the ESL Orchestrator. It connects to the Vusion ecosystem APIs, fetches store and entity data, normalises it, and writes it to PostgreSQL using upsert semantics. It runs as a Kubernetes CronJob on a configurable schedule.

The pipeline supports **incremental synchronisation** — on subsequent runs, it only fetches records modified since the last successful sync for each store, reducing API calls by 60–98% compared to a full sync.

## Technology Stack

| Technology | Version | Purpose |
|---|---|---|
| Go | 1.25+ | Application language |
| Cobra | — | CLI framework |
| pgx/v5 | — | PostgreSQL driver with connection pooling |
| Zap | — | Structured logging |
| OpenTelemetry | — | Distributed tracing and metrics |
| Viper | — | Configuration management with env var overrides |

## Architecture

The pipeline follows a **Connector → Transformer → Sink** pattern:

![Pipeline Architecture](diagrams/pipeline.svg)

1. **Connector** — Fetches data from Vusion Manager and VLink APIs
2. **Transformer** — Normalises records (field extraction, snake_case conversion)
3. **Sink** — Writes normalised records to PostgreSQL in batches

Records flow through buffered channels, processed by a configurable number of concurrent workers.

## CLI

The pipeline ships as a single binary (`eslorchestrator`) with three subcommands:

### run

Executes the pipeline using the provided configuration file.

```bash
eslorchestrator run config.yaml
eslorchestrator run -c config.yaml --log-level debug
eslorchestrator run config.yaml -v   # verbose (sets log-level to debug)
```

| Flag | Default | Description |
|---|---|---|
| `-c, --config` | `$HOME/.eslorchestrator.yaml` | Config file path |
| `-l, --log-level` | `info` | Logging level: debug, info, warn, error |
| `-v, --verbose` | `false` | Enable verbose output |

Each invocation generates a unique execution ID (UUID) for tracing across logs.

### validate

Validates configuration syntax and structure without executing the pipeline.

```bash
eslorchestrator validate config.yaml
```

Outputs pipeline metadata on success: name, transform type, sink type, worker count, buffer size, and telemetry status.

### version

Displays build information: version, commit hash, build date, Go version, and platform.

```bash
eslorchestrator version
```

## Connector

The Vusion connector implements a two-phase synchronisation strategy:

### Phase 1 — Store Discovery

1. Fetch all stores from the Vusion Manager API (paginated, page size: 100)
2. Emit store records to the pipeline output channel
3. Buffer stores in memory for Phase 2
4. Apply store filters:
   - `filter_stores` — explicit list of store IDs (takes priority)
   - `filter_retail_chains` — retail chain IDs (used only if `filter_stores` is empty)
   - Both empty — process all stores

### Phase 2 — Per-Store Entity Fetching

1. Load the latest successful sync state per store from the database
2. Launch a worker pool (`store_concurrency`, default: 10) to process stores in parallel
3. For each store, determine sync mode:
   - **Full sync** — no prior successful run exists → fetch all records
   - **Incremental sync** — prior run exists → fetch records modified since `synced_at - lookback_window`
4. Fetch products, labels, and access points from VLink API

### External APIs

**Vusion Manager** — store metadata:

- Endpoint: `/stores/search`
- Returns: store ID, retail chain, name, software settings, timestamps
- Auth: `Ocp-Apim-Subscription-Key` and `ApiKey` headers

**VLink** — per-store entity data:

- Endpoints:
  - `/stores/{storeID}/products` (full sync)
  - `/stores/{storeID}/products/modified-since?since={timestamp}` (incremental)
  - `/stores/{storeID}/labels` and `/stores/{storeID}/labels/modified-since?since={timestamp}`
- Page size: 1000
- Auth: same headers as Vusion Manager

**Access points** are extracted directly from the store object (`transmissionSystems.highFrequency.transmitters`), not fetched via a separate API call.

### Error Handling

- Phase 1 failure (store fetch) — pipeline aborts immediately
- Phase 2 failure (single store) — other stores continue processing; failure recorded in state

## Transformer

The normaliser transformer extracts fields from nested API responses and flattens them into database-ready column names.

### Transformation Steps

1. Extract values using dot-notation paths (e.g., `software.setting.fileName`)
2. Convert field names to snake_case (`fileName` → `file_name`)
3. Flatten nested paths (`software.setting.fileName` → `software_setting_file_name`)
4. Remove internal fields (e.g., `_score`)

### Entity Field Mappings

Each entity type has a defined set of fields to extract:

**Store** — 9 fields: `retail_chain_id`, `store_id`, `store_name`, `retail_chain_name`, `software_setting_file_name`, `software_setting_version`, `software_setting_last_update`, `creation_date`, `modification_date`

**Product** — 45+ fields: core attributes (`item_id`, `name`, `description`, `brand`, `price`, `status`), matching data (`matching_count`, `matching_matched`, `matching_labels`), and 30+ custom fields (`custom_dept`, `custom_class`, `custom_status`, etc.)

**Label** — 30+ fields: hardware info (`hardware_type_name`, `hardware_battery`), transmission history (`transmission_registration_date`, `transmission_last_successful_transmission_date`), matching details, and connectivity status

**Access Point** — 12 fields: identifiers (`id`, `mac_address`, `serial_number`), status, channel, and connectivity data

## Sink

The PostgreSQL sink writes normalised records using batched upsert operations.

### Batching

Records are queued to a background worker that flushes a batch when any of these conditions is met:

| Condition | Default | Config Key |
|---|---|---|
| Batch reaches size limit | 100 records | `sink.postgres.batch_size` |
| Time since first record in batch | 1s | `sink.postgres.batch_timeout` |
| No new records (idle) | 100ms | `sink.postgres.idle_flush_timeout` |

### Upsert Logic

Each batch is executed as a single transaction using `pgx.Batch`:

```sql
INSERT INTO {table} ({columns})
VALUES ($1, $2, ...)
ON CONFLICT ({conflict_keys})
DO UPDATE SET {column} = EXCLUDED.{column}, ...
```

Conflict keys are configured per entity type (e.g., `item_id, store_id, retail_chain_id` for products).

### Error Handling and Retry

Failed records are classified as **permanent** or **transient**:

| Type | PG Error Codes | Action |
|---|---|---|
| Permanent | 23505 (unique violation), 23502 (not null), 42601 (syntax) | Stored in `records_with_errors`, not retried |
| Transient | 40P01/40001 (deadlock), 57P01–57P03 (system) | Retried with exponential backoff |

Retry configuration:

| Setting | Default | Config Key |
|---|---|---|
| Max retries | 3 | `sink.postgres.max_retries` |
| Initial delay | 1s | `sink.postgres.retry_delay` |
| Backoff multiplier | 2.0 | `sink.postgres.retry_backoff` |
| Max delay | 30s | `sink.postgres.max_retry_delay` |

### Connection Pool

| Setting | Default | Config Key |
|---|---|---|
| Max connections | 10 | `sink.postgres.max_connections` |
| Min connections | 2 | `sink.postgres.min_connections` |
| Max lifetime | 1h | `sink.postgres.max_conn_lifetime` |
| Idle timeout | 30m | `sink.postgres.max_conn_idle_time` |
| Health check | 1m | `sink.postgres.health_check_period` |

## State Management

The pipeline tracks synchronisation history in two database tables to enable per-store incremental sync decisions.

### sync_state

One row per pipeline run. Records aggregate metrics: total stores/products/labels/access points processed, duration, status, and error message.

### store_sync_state

One row per store per run. Records per-store metrics and the `synced_at` timestamp — the pipeline start time (not finish time) — which is used as the incremental sync cutoff on the next run.

### Sync Mode Decision

For each store in a run:

1. Query `store_sync_state` for the most recent **successful** run
2. If no successful run exists → **full sync**
3. If a successful run exists → **incremental sync** with cutoff = `synced_at - lookback_window`

The `lookback_window` (e.g., `5m`) provides a safety margin against clock skew between systems.

## Configuration Reference

The pipeline is configured via a YAML file with environment variable overrides. Env vars use uppercase dot-to-underscore notation (e.g., `CONNECTOR_TIMEOUT`).

### Pipeline

```yaml
pipeline:
  name: "esl-orchestrator"          # Required — pipeline identifier
  description: "ESL sync pipeline"  # Optional
  performance:
    worker_count: 10                # Concurrent transform workers
    buffer_size: 1000               # Channel buffer capacity
```

### Connector

```yaml
connector:
  vusion_manager:
    base_url: "https://..."         # Required
    subscription_key: "..."         # Required
    api_key: "..."                  # Required
  vlink:
    base_url: "https://..."         # Required
    subscription_key: "..."         # Required
    api_key: "..."                  # Required
  timeout: "30s"                    # HTTP client timeout
  buffer_size: 500                  # Record stream buffer
  store_concurrency: 10             # Parallel store processing
  filter_stores: []                 # Explicit store IDs (takes priority)
  filter_retail_chains: []          # Retail chain IDs (fallback)
  sync:
    lookback_window: "5m"           # Safety margin for incremental cutoff
    state_store:
      type: "postgres"
      postgres:
        host: "localhost"
        port: 5432
        database: "eslorchestrator"
        username: "..."
        password: "..."
        schema: "esl"
        ssl_mode: "disable"
```

### Transform

```yaml
transform:
  type: "normalizer"                # "normalizer" or "passthrough"
```

### Sink

```yaml
sink:
  type: "postgres"
  postgres:
    host: "localhost"
    port: 5432
    database: "eslorchestrator"
    username: "..."
    password: "..."
    schema: "esl"
    ssl_mode: "disable"
    batch_size: 500
    batch_timeout: "5s"
    max_retries: 3
    max_connections: 10
    tables:
      store:
        name: "stores"
        conflict_keys: ["store_id", "retail_chain_id"]
      product:
        name: "products"
        conflict_keys: ["item_id", "store_id", "retail_chain_id"]
      label:
        name: "labels"
        conflict_keys: ["label_id", "store_id", "retail_chain_id"]
      accesspoint:
        name: "access_points"
        conflict_keys: ["id", "store_id", "retail_chain_id"]
```

### Telemetry

```yaml
telemetry:
  enabled: true
  otlp_endpoint: "localhost:4317"
  service_name: "eslorchestrator"
  service_version: "1.0.0"
  environment: "production"
```

## Observability

### Structured Logging

All log entries include the execution ID, pipeline name, and contextual fields (store ID, entity type, record count). Log level is configurable via `--log-level` flag or `LOG_LEVEL` environment variable.

### Distributed Tracing

When telemetry is enabled, the pipeline emits OpenTelemetry spans via OTLP/gRPC:

| Span | Scope |
|---|---|
| `pipeline.run` | Overall pipeline execution |
| `connector.vusion.read` | Vusion API data fetch |
| `pipeline.process_record` | Individual record processing |
| `sink.postgres.write` | Record queuing to sink |
| `sink.postgres.write_batch` | Batch execution |

### Metrics

| Metric | Type | Description |
|---|---|---|
| `pipeline.records.processed` | Counter | Successfully processed records |
| `pipeline.records.failed` | Counter | Failed records |
| `connector.records.read` | Counter | Records fetched from source |
| `sink.records.written` | Counter | Records written to database |
| `pipeline.run.duration` | Histogram | Total run duration (ms) |
| `connector.latency` | Histogram | API fetch latency (ms) |
| `sink.latency` | Histogram | Write latency (ms) |

All metrics are prefixed with `eslorchestrator.` and include attributes for pipeline name, entity type, and error classification.
