# Plan: phase2-cdc-event-publisher

**Scope:** New `event-publisher` repository
**Depends on:** shared package (esl-common latest commit on main — includes `entity`, `event`, and `postgres` packages), go-solace-sdk, database migrations

## Repository setup (pre-implementation) — DONE

1. ~~Delete template leftovers: `database/`, `flyway.conf`~~
2. ~~Rewrite `README.md` with proper project content~~
3. ~~Scaffold Go module: `go.mod`, directory structure (`cmd/`, `internal/`)~~
4. ~~Add `Makefile` with all targets (build, test, test-integration, lint, install-lint, run, docker-build)~~
5. ~~Add `.golangci.yml` (v2 format)~~
6. ~~Add `Dockerfile` (multi-stage build)~~
7. ~~Add initial `config.yaml` (application config, not CI)~~

Committed: `b72967c` — pushed to `main`.

## Architecture

Long-running Go service deployed as K8s Deployment. Polls the outbox table and publishes to Solace.

## Stack

| Concern | Library | Version |
| --- | --- | --- |
| Go | `go` | 1.25 |
| CLI | Plain `main()` | — |
| Config | `github.com/spf13/viper` | latest |
| Logging | `go.uber.org/zap` (app) + `slog` adapter for go-solace-sdk | latest |
| DB | `github.com/jackc/pgx/v5` via esl-common `postgres` package | — |
| Solace | `go-solace-sdk` (internal, wraps `solace.dev/go/messaging`) | latest |
| UUID | `github.com/google/uuid` | latest |
| Testing | `github.com/stretchr/testify` + `testcontainers-go` | latest |
| Linting | `golangci-lint` v2 | pinned in Makefile |
| Observability | `go.opentelemetry.io/otel` (metrics via go-solace-sdk OTel support) | latest |

### Logging setup

- Application code uses `zap` for structured JSON logging (consistent with datapipeline/datafetch)
- go-solace-sdk expects `*slog.Logger` — bridge via `zapslog.NewHandler(zapLogger.Core())` to funnel all output through zap

## Core loop

```
Poll (1s interval) → SELECT WHERE status = 'PENDING' (FOR UPDATE SKIP LOCKED)
  → Validate entity_type against entity.EntityType enum
  → Transform outbox row into published event (generate eventId, split store_id, merge fields)
  → Publish each to Solace dynamic topic (persistent/confirmed):
      in-store/orchestratoresl/{entitySegment}/{messageType}/v1/{insignia}/{storeId}
  → On success: UPDATE status = 'DELIVERED', delivered_at = NOW()
  → On failure: UPDATE status = 'FAILED'
  → Commit transaction
```

### Batch failure handling

Events are published one by one within the batch. On failure:

1. Events already published → marked as `DELIVERED`
2. The failed event → marked as `FAILED`
3. Remaining events → stay `PENDING` for next poll

This guarantees **at-least-once delivery** and **no lost events**. In rare crash scenarios (process dies mid-batch, between publishing to Solace and committing to PostgreSQL), some events may be re-published on recovery. Consumers deduplicate using the outbox `id` (UUID), which is included as `eventId` in every published event and is deterministic across retries. The system relies on go-solace-sdk's built-in retry policy (3 attempts, exponential backoff) before considering a publish as failed. No additional outer retry — if the SDK fails, the event is marked `FAILED` immediately.

### Transaction strategy

Single transaction: `SELECT FOR UPDATE SKIP LOCKED` → publish → `UPDATE` → `COMMIT`. Rows stay locked during Solace publish. This is acceptable because:

- Datapipeline only INSERTs into the outbox (no conflict with row locks)
- Batch size is capped (100 events)
- Single publisher instance expected

**Scaling note:** `FOR UPDATE SKIP LOCKED` naturally supports multiple replicas — PostgreSQL skips rows already locked by other transactions, so each replica automatically gets a distinct set of rows with no coordination needed. The only caveat is **event ordering per entity**: with multiple replicas, two events for the same entity could be picked up by different replicas and published out of order. If downstream consumers require per-entity ordering, this would need partitioning by entity key (e.g. consistent hashing). For now, single replica is sufficient.

**Note:** Use `entity.EntityType` from esl-common when reading `entity_type` from the outbox table and when resolving the Solace topic segment. This provides compile-time safety and consistency with the datapipeline.

## Event transformation

The outbox row is transformed into a published event before sending to Solace:

1. Generate `eventId` (UUID v4 via `google/uuid`)
2. Extract `retail_chain_id` from `EntityKey` (used as `insignia` in the topic)
3. Extract and **split** `store_id` from `EntityKey` — the outbox stores it as `{retail_chain_id}.{store_id}` (e.g. `continente_pt.000010`), split on `.` and take only the second part (`000010`) for both the published event and the topic
4. Merge `EntityKey` fields as top-level keys (with the split `store_id`)
5. Merge `Payload` fields as top-level keys (all entity-specific data)
6. Set `send_date` to current time (ISO 8601 / RFC3339)

All timestamps in the published event are ISO 8601 format. Source timestamps from the outbox payload are already ISO 8601 (datapipeline normalizes them). `send_date` is generated by the event-publisher in the same format.

The `EventType` and `EntityType` fields from the outbox row are not included in the published event — `EntityType` is used for topic routing, `EventType` is lowercased for the `{messageType}` topic segment.

### Payload format by event type

**CREATED** — `Payload` contains all entity fields as flat key-value pairs (excluding conflict keys, which are in `EntityKey`). Includes `created_at` and `last_updated_at`. After merging `EntityKey` + `Payload`, the result is a flat JSON object matching the entity schemas.

**UPDATED** — `Payload` contains a **mix** of two formats:

- **Changed business fields**: nested diff objects `{"old": X, "new": Y}`
- **Audit columns** (`created_at`, `last_updated_at`): flat string values (always included, not as diffs)

Example UPDATED payload from the outbox:

```json
{
  "name": {"old": "Store Alpha", "new": "Store Beta"},
  "status": {"old": "active", "new": "inactive"},
  "created_at": "2026-03-01T10:00:00Z",
  "last_updated_at": "2026-04-06T14:30:00Z"
}
```

The published event is always **flat** — no `{old, new}` diffs are sent to Solace. The `{old, new}` structure stays in the outbox for auditing purposes only. The transform step uses the `event_type` column to decide how to handle the payload:

- **CREATED** (`event_type = 'CREATED'`): payload is already flat — merge as-is
- **UPDATED** (`event_type = 'MODIFIED'`): iterate payload fields — if a value is an object with a `"new"` key, extract only the `"new"` value; otherwise (audit columns) pass through as-is

The result is that both CREATED and UPDATED published events have the same flat structure: `eventId` + conflict keys + entity fields (current values only) + `send_date`. Downstream consumers distinguish between creation and update events via the Solace topic (`{messageType}` segment: `created` or `updated`), not the payload.

**Note:** Only `CREATED` and `UPDATED` events are handled in Phase 2. The datapipeline currently only generates these two types.

### Published event schemas

All entities share the same structure: `eventId` + conflict keys (with split `store_id`) + entity-specific payload fields + `send_date`. All timestamps are ISO 8601.

**Store** — required: `eventId`, `retail_chain_id`, `store_id`, `send_date`

Fields: `store_name`, `retail_chain_name`, `software_setting_version`, `creation_date`, `modification_date`, `last_updated_at`

**Product** — required: `eventId`, `retail_chain_id`, `store_id`, `item_id`, `send_date`

Fields: `name`, `description`, `brand`, `price`, `references` (array), `status`, `matching_count`, `matching_labels` (array), `custom_class`, `custom_demo_stock_night`, `custom_desc_promo`, `custom_desconto`, `custom_dept`, `custom_discount_desc`, `custom_fechafinal`, `custom_fechainicio`, `custom_precioantes`, `custom_preciounis`, `custom_preciouniwas`, `custom_pres_stock_night`, `custom_pvp_uom_desc`, `custom_pvr_is_description`, `custom_qty_on_order_night`, `custom_qty_sold`, `custom_rupt_alert_night`, `custom_rupt_alert_night_esl`, `custom_soh_night`, `custom_srp_init_night`, `custom_stock_in_transit_night`, `custom_status`, `custom_subclass`, `custom_ticket_subtype`, `custom_unidades`, `custom_validade_promocao`, `creation_date`, `modification_date`, `deletion_date`, `last_updated_at`

**Label** — required: `eventId`, `retail_chain_id`, `store_id`, `label_id`, `send_date`

Fields: `transmitter_id`, `previous_transmitter_id`, `status`, `hardware_type_name`, `hardware_battery`, `transmission_registration_date`, `transmission_transmission_date`, `transmission_last_failed_transmission_date`, `transmission_last_successful_transmission_date`, `matching_matching_date`, `matching_scenario_scenario_id`, `matching_items_item_id`, `matching_items_matched_item_id`, `matching_items_modification_date`, `connectivity_status`, `connectivity_modification_date`, `connectivity_signal_quality`, `connectivity_last_offline_date`, `connectivity_previous_status`, `connectivity_last_online_date`, `billing_activate_date`, `last_join_timestamp`, `creation_date`, `modification_date`, `created_at`, `last_updated_at`

**Access Point** — required: `eventId`, `retail_chain_id`, `store_id`, `id`, `send_date`

Fields: `mac_address`, `serial_number`, `channel`, `status`, `connectivity_status`, `connectivity_last_online_date`, `connectivity_last_offline_date`, `creation_date`, `modification_date`, `created_at`, `last_updated_at`

**Note:** The event-publisher does not need to know or validate the full field list — it merges all `EntityKey` + `Payload` fields as top-level keys. The schemas above are the contract with downstream consumers (reference: `Schema*.json` files).

### Solace topic structure

Topics follow a hierarchical pattern per entity type:

```text
in-store/orchestratoresl/{entitySegment}/{messageType}/v1/{insignia}/{storeId}
```

| Variable            | Source                                                       |
| ------------------- | ------------------------------------------------------------ |
| `{entitySegment}`   | Static mapping from `entity.EntityType` (see table below)    |
| `{messageType}`     | `event.ChangeType` lowercased: `created`, `updated`, `deleted` |
| `{insignia}`        | `retail_chain_id` from `EntityKey`                           |
| `{storeId}`         | `store_id` from `EntityKey`, split on `_`, take second part only |

**Entity type → topic segment mapping:**

| `entity.EntityType` | Topic segment          |
| -------------------- | ---------------------- |
| `store` | `stores/store` |
| `product` | `products/product` |
| `label` | `labels/label` |
| `accesspoint` | `accesspoints/accesspoint` |

**Example topics:**

- Store created: `in-store/orchestratoresl/stores/store/created/v1/continente_pt/000010`
- Product updated: `in-store/orchestratoresl/products/product/updated/v1/continente_pt/000010`
- Label created: `in-store/orchestratoresl/labels/label/created/v1/continente_pt/000010`
- Access point updated: `in-store/orchestratoresl/accesspoints/accesspoint/updated/v1/continente_pt/000010`

### Solace publishing

- Use **persistent/confirmed** messaging (`PublishConfirmed` / `PublishMessageConfirmed`) for guaranteed delivery with broker acknowledgment
- **Dynamic topics** per message via `Message.Destination` (not a fixed topic), built from entity type, event type, and entity key fields
- Rely on go-solace-sdk's built-in retry policy (3 attempts, 1s base delay, exponential backoff)
- `ErrConfirmationTimeout` from SDK = publish failure

## Components

- `cmd/eventpublisher/main.go` — entry point, signal handling, graceful shutdown
- `internal/relay/relay.go` — polling loop, batch processing
- `internal/relay/config.go` — config struct, validation
- `internal/outbox/repository.go` — outbox queries (SELECT PENDING, UPDATE DELIVERED/FAILED), interface for mocking
- `internal/outbox/model.go` — `OutboxRow` struct wrapping `event.ChangeEvent` with outbox fields (`id`, `status`, `delivered_at`)
- `internal/messaging/publisher.go` — `Publisher` interface (Connect, Publish, Disconnect, IsConnected)
- `internal/messaging/solace/client.go` — Solace implementation of `Publisher`, initializes go-solace-sdk Client + TopicPublisher from config
- `internal/health/health.go` — configurable `/health` and `/ready` endpoints
- `internal/transform/transform.go` — outbox row → published event transformation

## Database connection

Use `postgres.PoolConfig` and `postgres.NewPool` from esl-common for pool creation. The service maps its own YAML config to `postgres.PoolConfig`. Use `postgres.ClassifyError` and `postgres.IsTransient` for error handling.

## Config structure

**Note:** `schema` will be added to esl-common `postgres.PoolConfig` (setting `search_path` at pool level) before implementation. Once done, queries use unqualified table names. All database fields below map directly to `postgres.PoolConfig`.

```yaml
# PostgreSQL connection settings (all fields map to esl-common postgres.PoolConfig)
database:
  host: localhost              # database server hostname
  port: 5432                   # database server port
  user: esl                    # database user
  password: ""                 # database password
  database: esl                # database name
  schema: esl                  # schema for search_path (set at pool level)
  ssl_mode: disable            # SSL mode: disable, require, verify-ca, verify-full
  application_name: "event-publisher"  # application name sent to PostgreSQL (visible in pg_stat_activity)
  max_conns: 4                 # maximum number of connections in the pool
  min_conns: 1                 # minimum number of idle connections maintained
  max_conn_lifetime: "1h"      # maximum lifetime of a connection before it is closed and replaced
  max_conn_idle_time: "30m"    # maximum time a connection can sit idle before being closed
  health_check_period: "1m"    # how often idle connections are health-checked
  connect_timeout: "5s"        # timeout for establishing a new connection

# Solace broker connection and messaging settings
solace:
  host: tcp://localhost:55555   # broker URL (tcp:// or tcps:// for TLS)
  vpn: default                  # message VPN name
  username: admin               # broker authentication username
  password: admin               # broker authentication password
  topic_prefix: "in-store/orchestratoresl"  # base prefix for all published topics
  connect_timeout: "10s"        # TCP connection timeout (min: 1s)
  connect_retries: 3            # low-level TCP connect retry attempts (min: 0)
  reconnect_retries: 3          # reconnection attempts after disconnect (-1 for infinite, max: 10000)
  reconnect_wait: "2s"          # wait between reconnection attempts (min: 100ms)
  keep_alive: "30s"             # keep-alive interval for the connection
  confirmation_timeout: "10s"   # timeout waiting for publish confirmation from broker

# Polling and batch processing settings
publisher:
  poll_interval: "1s"       # how often to poll the outbox for pending events
  batch_size: 100           # max events to fetch per poll cycle
  shutdown_timeout: "30s"   # max time to wait for current batch to finish on shutdown

# Health check HTTP server settings (K8s probes)
health:
  port: 8081                # HTTP server port
  health_path: "/health"    # liveness probe path (always 200 if process is running)
  ready_path: "/ready"      # readiness probe path (200 if DB + Solace connected, 503 otherwise)

# Logging configuration
log:
  level: info               # debug, info, warn, error
```

## Health endpoints

- **`/health`** (liveness) — always returns `200 OK` if the process is running. Used by K8s liveness probe.
- **`/ready`** (readiness) — returns `200 OK` if DB pool is alive AND Solace client is connected. Returns `503 Service Unavailable` otherwise. Used by K8s readiness probe.
- Port and URL paths are configurable via `health.port`, `health.health_path`, `health.ready_path`.

## Graceful shutdown

On `SIGINT` / `SIGTERM`:

1. Stop accepting new poll cycles
2. Finish the current batch (publish remaining events, update statuses)
3. Disconnect Solace client
4. Close DB pool
5. Shutdown health server

Configurable shutdown timeout (`publisher.shutdown_timeout`, default 30s). If timeout is exceeded, force-kill.

## Observability

The event-publisher creates a shared `metric.MeterProvider` and passes it to go-solace-sdk via `WithMeterProvider(mp)`. The SDK automatically records its own metrics (`solace.core.*`, `solace.producer.*`) covering connection, publish success/failure, latency, retries, and payload size. The event-publisher adds application-level metrics that the SDK can't provide:

| Metric | Type | Attributes | Description |
|---|---|---|---|
| `event_publisher.events_processed_total` | Counter | `entity_type`, `event_type`, `status` | Events processed, segmented by entity (store, product, etc.), event type (created, updated), and outcome (delivered, failed) |
| `event_publisher.poll_batch_size` | Histogram | — | Number of events fetched per poll cycle |
| `event_publisher.poll_cycles_total` | Counter | — | Total poll cycles executed (including empty ones) |

## Dockerfile

Multi-stage build following the datapipeline pattern (distroless, non-root, versioning, cross-platform).

**Before writing the Dockerfile**, run `docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot` to get the current digest and use it in the `FROM` line (e.g. `FROM gcr.io/distroless/static-debian12:nonroot@sha256:<current>`). Add a comment with the pin date.

```dockerfile
# Build arguments for versioning and metadata
ARG VERSION=dev
ARG COMMIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG TARGETOS=linux
ARG TARGETARCH=amd64

# Builder stage
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG VERSION
ARG COMMIT_SHA
ARG BUILD_DATE

# Install build dependencies
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /build

# Copy dependency files first for better layer caching
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy source code
COPY . .

# Build the application with optimizations
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT_SHA} -X main.buildDate=${BUILD_DATE}" \
    -trimpath \
    -o eventpublisher \
    ./cmd/eventpublisher

# Final stage using distroless for minimal attack surface
# Digest pinned on <DATE>. To update: docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot
FROM gcr.io/distroless/static-debian12:nonroot@sha256:<pin at implementation time>

# Redeclare build arguments for use in final stage
ARG VERSION=dev
ARG COMMIT_SHA=unknown
ARG BUILD_DATE=unknown

# Copy timezone data and CA certificates from builder
COPY --from=builder --chown=nonroot:nonroot /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder --chown=nonroot:nonroot /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the binary
COPY --from=builder --chown=nonroot:nonroot /build/eventpublisher /app/eventpublisher

WORKDIR /app

# Use non-root user (provided by distroless nonroot image)
USER nonroot:nonroot

# Add labels for metadata (OCI standard)
LABEL org.opencontainers.image.title="ESL Event Publisher" \
    org.opencontainers.image.description="Polls outbox table and publishes CDC events to Solace" \
    org.opencontainers.image.version="${VERSION}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.source="https://github.com/sonaemc-instore/lac1041-instoreorchestrator_event-publisher" \
    org.opencontainers.image.revision="${COMMIT_SHA}"

# Run the application
ENTRYPOINT ["/app/eventpublisher"]
```

## Code quality: golangci-lint

Follow the same approach as `esl-common`:

- Add `.golangci.yml` (v2 format) with: `errcheck`, `gosec`, `staticcheck`, `ineffassign`, and `gofumpt` formatter
- Makefile with `GOLANGCI_LINT_VERSION` variable, `install-lint` target (pinned version, auto-install), and `lint` target depending on `install-lint`
- `make lint` must pass with 0 issues

## Makefile targets

- `build` — compile the binary
- `test` — run unit tests (`go test ./...`)
- `test-integration` — run all tests including integration (`go test -tags=integration ./...`)
- `lint` — run golangci-lint (depends on `install-lint`)
- `install-lint` — install pinned golangci-lint version
- `run` — build and run locally
- `docker-build` — build Docker image
- `mock-gen` — generate mocks via mockery (depends on `install-mockery`)
- `install-mockery` — install pinned mockery version (v3.6.1)

## Testing

### Strategy

- **Unit tests:** run by default (`go test ./...`), polling logic with mock DB, Solace publish mock
- **Integration tests:** behind `//go:build integration` build tag (matches esl-common pattern), run with `go test -tags=integration ./...`
  - **Full E2E:** testcontainers for both PostgreSQL and Solace (`solace/solace-pubsub-standard:latest`)
  - Insert outbox rows → publisher picks up → publishes to real Solace broker → marks delivered
  - Health endpoint responds correctly when DB/Solace connected vs disconnected
  - Solace testcontainer setup: copy/adapt go-solace-sdk's `internal/testutil/solace_container.go` pattern into event-publisher (can't import internal package directly)

### Best practices

- **Table-driven tests** for all cases with multiple inputs/outputs
- **testify** for assertions (`require` for fatal, `assert` for non-fatal)
- **Test naming:** `Test<Function>_<scenario>` (e.g. `TestPublisher_SkipsDeletedEvents`)
- No test logic in production code (no `if testing` guards)
- **Mocks:** generated via mockery v3.6.1 (same setup as datapipeline). `.mockery.yml` at project root with explicit interface lists, generated into top-level `mocks/` directory. Testify template, goimports formatter, naming: `{{.InterfaceName | snakecase}}_mock.go`

### Verification after every change

Run after every code change (implementation, fix, refactor):

```sh
make lint && go test -tags=integration ./...
```

Both must pass with 0 issues before considering work complete.

---

## Post-implementation (this repo)

1. Update `README.md` with final documentation (architecture, config, how to run, how to test)

## Post-implementation (esl-documentation — steps 7/8)

1. Create Excalidraw diagrams (exported as SVG) in `esl-documentation/phase-2/diagrams/`, following the Phase 1 convention:
   - Architecture — CDC pipeline flow (replace ASCII art in `02-architecture.md`)
   - ER diagram — updated with the `event_outbox` table
   - Event Publisher flow — poll → transform → publish → update cycle
