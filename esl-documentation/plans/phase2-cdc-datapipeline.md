# Plan: phase2-cdc-datapipeline

**Scope:** `datapipeline` project — CDC detection in the sink
**Depends on:** shared package (esl-common latest commit on main), database migrations (V1.0.0.15–17)
**Status:** Prerequisites done — CDC implementation not started

## Prerequisite tasks

### ~~Refactor: replace hardcoded entity strings with `entity.EntityType`~~ ✅ DONE (2026-04-06, commit 42a6a7e)

### ~~Code quality: add golangci-lint config~~ ✅ DONE (2026-03-31, commit a62bdd4)

### ~~Refactor: adopt `postgres` package from esl-common~~ ✅ DONE (2026-04-06, commit 2bae4c5)

Includes: pool creation via `commonpg.NewPool`, error classification via `commonpg.IsTransient`/`ClassifyError`, `classifyJoined` bug fix, `context.Context` threaded from caller through `Build`/`New`, integration test table schema fixes, and rewritten broken integration tests (CHECK constraint violations instead of impossible unique violations in upsert mode).

---

## CDC Implementation

### Design decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Single-writer assumption | READ COMMITTED (default) | The datapipeline is the sole writer to entity tables. No concurrent writes means no risk of missed diffs between SELECT and upsert. If another service starts writing, revisit isolation level (SERIALIZABLE or row-level locking). Add code comment at `pool.Begin()`. |
| Conflict keys for CDC | `entity.ConflictKeys` from esl-common | Single source of truth for entity business keys. YAML `TableConfig.ConflictKeys` stays only for the upsert `ON CONFLICT` clause. Follow-up: remove YAML `ConflictKeys` duplication and have the upsert builder also read from `entity.ConflictKeys`. |
| Type comparison | `::TEXT` cast in SELECT + string normalization | Avoids pgtype vs native Go type mismatches. Both sides normalized to string for comparison. |
| Column selection | Explicit column list from `RawData` keys | No `SELECT *` — only fetch columns being upserted. Avoids false diffs from DB-only columns. |
| Error handling | First failing record stored + error propagated | CDC batch is atomic — first error rolls back everything. Store the triggering record in `records_with_errors` for debugging, propagate error via `Ack(err)` to all records in the batch. |

### Column handling in events

| Column category | Comparison | CREATED payload | UPDATED payload |
|---|---|---|---|
| Conflict keys | Skip | Skip (in `EntityKey`) | Skip (in `EntityKey`) |
| `created_at` | Skip | Include | Include (flat value) |
| `last_updated_at` | Skip | Include | Include (flat value) |
| Business fields | Compare | Include | Only changed fields as `{"old": X, "new": Y}` |

### Performance design

**Current (CDC disabled)**: 1 network round-trip (`pool.SendBatch` with auto-commit per statement).

**CDC path**:

```text
BEGIN                              → 1 RT
tx.SendBatch(SELECT per entity)    → 1 RT  (fetch existing state)
  └─ classify diffs in Go          → 0 RT  (CPU only)
tx.SendBatch(upserts)              → 1 RT  (same as today)
tx.SendBatch(outbox inserts)       → 1 RT  (only if changes detected)
COMMIT                             → 1 RT
```

Total: 4–5 RTs. Each phase is a clean, single-responsibility step.

> An earlier draft combined SELECT + upserts into one SendBatch to save 1 RT.
> Dropped: the coupling violated SRP and saved only ~0.1ms on LAN — not worth the complexity.

**Error semantics**: CDC path rolls back entire batch on any failure (vs current per-record continuation). Required because partial upserts + partial outbox is invalid. All records in the batch receive the same error via `Ack(err)`. The first failing record is stored in `records_with_errors` for diagnostics.

**No deadlock risk**: The sink has a single worker goroutine (`startWorker`). All stores' records flow through a shared channel, and batches are flushed sequentially — never concurrently.

### Files to modify

| File | Change |
| ---- | ------ |
| `internal/sink/postgres/config.go` | Add `CDCConfig` struct + `CDC` field |
| `internal/sink/postgres/postgres.go` | Add `Begin` to `DBPool` interface |
| `internal/sink/postgres/builder.go` | Create `CDC` instance when enabled |
| `internal/sink/postgres/cdc.go` | **NEW** — `CDC` struct + helpers |
| `internal/sink/postgres/write_batch.go` | Extract `buildUpsertBatch`, add `executeBatchWithCDC` |
| `mocks/db_pool_mock.go` | Regenerate via `make mock-gen` |

### New files

| File | Purpose |
| ---- | ------- |
| `internal/sink/postgres/cdc.go` | CDC struct, detection logic, outbox writing |
| `internal/sink/postgres/cdc_test.go` | Unit tests for pure CDC functions |
| `internal/sink/postgres/cdc_integration_test.go` | Integration tests against real Postgres |
| `internal/sink/postgres/cdc_benchmark_test.go` | Benchmark: CDC vs non-CDC path |

---

### Architecture (SOLID)

#### CDC as an encapsulated struct (SRP, OCP)

All CDC logic lives in a `CDC` struct with two public methods. The sink delegates to it — adding event types or detection logic only touches CDC, never the sink.

```go
// CDC coordinates change detection for the transactional outbox pattern.
type CDC struct {
    schema  string
    logger  *logger.Logger
    metrics *telemetry.Metrics
}

// DetectChanges groups records by entity type, fetches existing state,
// and classifies each record as CREATED, UPDATED, or unchanged.
func (c *CDC) DetectChanges(
    ctx context.Context,
    tx pgx.Tx,
    records []*models.Record,
    tables map[string]TableConfig,
) ([]event.ChangeEvent, error)

// WriteOutbox inserts change events into event_outbox within the tx.
func (c *CDC) WriteOutbox(
    ctx context.Context,
    tx pgx.Tx,
    events []event.ChangeEvent,
) error
```

#### Extracted reusable helpers (DRY)

Two pieces of logic are currently inlined in `executeBatch` and would be duplicated in the CDC path. Extract both so both paths reuse them:

**`buildUpsertBatch`** — query preparation:

```go
// buildUpsertBatch builds a pgx.Batch with upsert queries for all records.
// Used by both executeBatch (non-CDC) and executeBatchWithCDC.
func (s *PostgresSink) buildUpsertBatch(
    records []*models.Record,
) (*pgx.Batch, error)
```

**`sendAndProcessBatch`** — batch result processing:

The loop that calls `br.Exec()` per record, builds `recordFailure` structs, and handles errors is identical in both paths except for the error strategy: non-CDC collects all failures, CDC fails fast on the first error. Extract it with a `failFast` parameter:

```go
// sendAndProcessBatch sends a batch and processes results.
// When failFast is true (CDC path), it returns on the first error with a
// single recordFailure. When false (non-CDC path), it collects all failures.
func (s *PostgresSink) sendAndProcessBatch(
    ctx context.Context,
    br pgx.BatchResults,
    records []*models.Record,
    failFast bool,
) ([]recordFailure, error)
```

Both `executeBatch` and `executeBatchWithCDC` call this after obtaining `BatchResults` from their respective senders (`s.pool` vs `tx`). The only difference is the sender and the `failFast` flag — the result processing, `recordFailure` construction, and error classification are fully shared.

#### Thin orchestrator (ISP, DIP)

`executeBatchWithCDC` is a small coordinator — it owns the transaction lifecycle and delegates each step. Returns `([]recordFailure, error)` to match the non-CDC `executeBatch` signature, enabling `writeBatch` to store the failing record in `records_with_errors` after retry exhaustion.

```go
func (s *PostgresSink) executeBatchWithCDC(ctx, records) ([]recordFailure, error) {
    // Uses READ COMMITTED (default). Safe because the datapipeline is the
    // sole writer to entity tables — no concurrent modifications between
    // SELECT and upsert. Revisit if another service starts writing.
    tx, _ := s.pool.Begin(ctx)
    defer tx.Rollback(ctx)

    events, _ := s.cdc.DetectChanges(ctx, tx, records, s.config.Tables)

    batch, _ := s.buildUpsertBatch(records)                        // DRY: shared
    br := tx.SendBatch(ctx, batch)
    failures, err := s.sendAndProcessBatch(ctx, br, records, true) // DRY: shared, failFast=true
    if err != nil {
        return failures, err
    }

    if len(events) > 0 {
        s.cdc.WriteOutbox(ctx, tx, events)
    }
    return nil, tx.Commit(ctx)
}
```

#### PostgresSink wiring

```go
type PostgresSink struct {
    // ... existing fields
    cdc *CDC  // nil when CDC disabled
}
```

Initialized in `Builder.Build()` only when `config.CDC.Enabled`. The dispatch in `executeBatch` checks `s.cdc != nil` — no need to inspect config at runtime.

---

### Step 1: Config — add CDC flag

**File: `internal/sink/postgres/config.go`**

```go
type CDCConfig struct {
    Enabled bool `mapstructure:"enabled"`
}
```

Add `CDC CDCConfig` field to `Config` struct:

```go
CDC CDCConfig `mapstructure:"cdc"`
```

No defaults needed (`Enabled` defaults to `false`).

### Step 2: DBPool interface — add Begin

**File: `internal/sink/postgres/postgres.go`**

Add to `DBPool` interface:

```go
Begin(ctx context.Context) (pgx.Tx, error)
```

`pgxpool.Pool` already implements this. Regenerate mock via `make mock-gen`.

### Step 3: Builder — wire CDC

**File: `internal/sink/postgres/builder.go`**

In `Build()`, after creating the sink struct:

```go
if b.config.CDC.Enabled {
    sink.cdc = NewCDC(b.config.Schema, b.logger, b.metrics)
}
```

### Step 4: CDC module

**New file: `internal/sink/postgres/cdc.go`**

#### Package-level constants

```go
var auditColumns = map[string]bool{
    "created_at":      true,
    "last_updated_at": true,
}
```

#### Private helpers (unit-testable pure functions)

**`groupByEntityType`** — groups records by `Metadata["type"]`:

```go
func groupByEntityType(
    records []*models.Record,
    tables map[string]TableConfig,
) map[string]entityGroup

type entityGroup struct {
    tableName    string
    conflictKeys []string   // from entity.ConflictKeys, used for fetch + event key
    records      []*models.Record
}
```

Uses `entity.ConflictKeys[entityType]` as the source of truth for business keys. Skips entity types not present in `entity.ConflictKeys` (cannot build events without known business keys).

**`buildEntityKey`** — builds lookup key + JSON-serializable key map:

```go
func buildEntityKey(data map[string]any, conflictKeys []string) (string, map[string]string)
```

- Lookup string: values joined with `"|"` (e.g. `"RC001|S001|P001"`)
- Key map: `{"retail_chain_id": "RC001", ...}`
- Uses `fmt.Sprintf("%v", val)` to normalize

**`buildFetchQuery`** — builds SELECT with explicit column list and `::TEXT` casting:

```go
func buildFetchQuery(
    schema, tableName string,
    conflictKeys []string,
    columns []string,
    records []*models.Record,
) (string, []any)
```

Generates:

```sql
SELECT col1::TEXT, col2::TEXT, ... FROM schema.table
WHERE (pk1, pk2) IN (($1,$2), ($3,$4), ...)
```

The `columns` list is derived from `RawData` keys of the first record in the group. Only fetches columns being upserted — no `SELECT *`.

**`normalizeValue`** — converts any Go value to its string representation for comparison:

```go
func normalizeValue(v any) string
```

Handles the types present in `RawData` (from JSON deserialization):
- `string` → as-is
- `float64` → format as number, strip trailing `.0` for whole numbers
- `bool` → `"true"` / `"false"`
- `[]any` (string slices from JSON) → sort, JSON marshal
- `nil` → `"<nil>"`
- Everything else → `fmt.Sprintf("%v", v)`

DB values arrive as `string` (via `::TEXT` cast) and are compared directly against normalized `RawData` values.

**`classifyAndDiff`** — compares incoming vs existing, returns change events:

```go
func classifyAndDiff(
    existing map[string]map[string]any,
    records []*models.Record,
    entityType string,
    conflictKeys []string,
) []event.ChangeEvent
```

- Key not in existing → `event.ChangeTypeCreated` (payload = all fields except conflict keys)
- Key in existing, fields differ → `event.ChangeTypeUpdated` (payload = `{"field": {"old": X, "new": Y}}` for changed business fields, plus `created_at` and `last_updated_at` as flat values)
- Identical → skip
- Comparison skips audit columns and conflict keys
- Both sides normalized to string before comparison

**`buildOutboxInsert`** — builds single multi-row INSERT for efficiency:

```go
func buildOutboxInsert(schema string, events []event.ChangeEvent) (string, []any)
```

Generates: `INSERT INTO schema.event_outbox (event_type, entity_type, entity_key, payload, occurred_at) VALUES ($1,$2,$3,$4,$5), ($6,$7,$8,$9,$10), ...`

#### Public methods

**`DetectChanges`** — orchestrates fetch + classify per entity type:

```go
func (c *CDC) DetectChanges(ctx, tx, records, tables) ([]event.ChangeEvent, error) {
    groups := groupByEntityType(records, tables)
    var allEvents []event.ChangeEvent

    for entityType, group := range groups {
        // Build column list from first record's RawData keys
        columns := sortedKeys(group.records[0].RawData)

        query, args := buildFetchQuery(c.schema, group.tableName, group.conflictKeys, columns, group.records)
        rows, _ := tx.Query(ctx, query, args...)

        // All values arrive as string due to ::TEXT casting
        existingRows, _ := pgx.CollectRows(rows, pgx.RowToMap)

        existing := make(map[string]map[string]any, len(existingRows))
        for _, row := range existingRows {
            key, _ := buildEntityKey(row, group.conflictKeys)
            existing[key] = row
        }

        events := classifyAndDiff(existing, group.records, entityType, group.conflictKeys)
        allEvents = append(allEvents, events...)
    }
    // log + metrics for fetch + classify durations and event counts
    return allEvents, nil
}
```

**`WriteOutbox`** — sends outbox insert on the transaction:

```go
func (c *CDC) WriteOutbox(ctx, tx, events) error {
    query, args := buildOutboxInsert(c.schema, events)
    _, err := tx.Exec(ctx, query, args...)
    // log + metrics
    return err
}
```

### Step 5: Batch execution — extract + CDC flow

**File: `internal/sink/postgres/write_batch.go`**

**Extract `buildUpsertBatch`** from `executeBatch` (DRY — query preparation):

```go
func (s *PostgresSink) buildUpsertBatch(records []*models.Record) (*pgx.Batch, error) {
    batch := &pgx.Batch{}
    for _, record := range records {
        query, args, _, err := s.prepareQuery(record)
        if err != nil {
            return nil, fmt.Errorf("failed to prepare record %s: %w", record.ID, err)
        }
        batch.Queue(query, args...)
    }
    return batch, nil
}
```

**Extract `sendAndProcessBatch`** from `executeBatch` (DRY — result processing):

Both paths iterate `br.Exec()` per record and build `recordFailure` on error. The only difference is the error strategy. This helper eliminates the duplication:

```go
// sendAndProcessBatch processes batch results from any sender (pool or tx).
// When failFast is true, returns on the first error with a single failure.
// When false, collects all failures and returns a joined error.
func (s *PostgresSink) sendAndProcessBatch(
    ctx context.Context,
    br pgx.BatchResults,
    records []*models.Record,
    failFast bool,
) ([]recordFailure, error) {
    defer br.Close() //nolint:errcheck

    var (
        batchErr error
        failures []recordFailure
    )
    for _, record := range records {
        _, err := br.Exec()
        if err == nil {
            continue
        }

        tableName, tblErr := s.getTableName(record)
        if tblErr != nil {
            tableName = "unknown"
        }
        failure := recordFailure{
            tableName: tableName,
            data:      record.RawData,
            err:       err,
            meta:      buildFailedMeta(record, err),
        }

        if failFast {
            return []recordFailure{failure}, classifyError(
                fmt.Errorf("failed to write record %s: %w", record.ID, err),
            )
        }

        failures = append(failures, failure)
        batchErr = errors.Join(
            batchErr,
            classifyError(fmt.Errorf(
                "failed to write record %s: %w", record.ID, err,
            )),
        )
    }

    if batchErr != nil {
        return failures, classifyJoined(batchErr)
    }
    return nil, nil
}
```

**Refactor `executeBatch`** to use both extracted helpers and dispatch CDC:

```go
func (s *PostgresSink) executeBatch(ctx, records) ([]recordFailure, error) {
    if s.cdc != nil {
        return s.executeBatchWithCDC(ctx, records)
    }

    prepareStart := time.Now()
    batch, err := s.buildUpsertBatch(records)
    if err != nil {
        return nil, err
    }
    prepareDuration := time.Since(prepareStart)

    executeStart := time.Now()
    br := s.pool.SendBatch(ctx, batch)
    failures, err := s.sendAndProcessBatch(ctx, br, records, false) // failFast=false
    executeDuration := time.Since(executeStart)

    // ... timing log unchanged
    return failures, err
}
```

**Add `executeBatchWithCDC`**:

```go
func (s *PostgresSink) executeBatchWithCDC(ctx, records) ([]recordFailure, error) {
    // Uses READ COMMITTED (default). Safe because the datapipeline is the
    // sole writer to entity tables — no concurrent modifications between
    // SELECT and upsert. Revisit if another service starts writing.
    tx, err := s.pool.Begin(ctx)
    if err != nil {
        return nil, classifyError(fmt.Errorf("begin transaction: %w", err))
    }
    defer tx.Rollback(ctx)

    // Phase 1: Detect changes (SELECT + classify)
    events, err := s.cdc.DetectChanges(ctx, tx, records, s.config.Tables)
    if err != nil {
        return nil, classifyError(fmt.Errorf("CDC detect changes: %w", err))
    }

    // Phase 2: Execute upserts (fail-fast via shared helper)
    batch, err := s.buildUpsertBatch(records)
    if err != nil {
        return nil, err
    }
    br := tx.SendBatch(ctx, batch)
    failures, err := s.sendAndProcessBatch(ctx, br, records, true) // failFast=true
    if err != nil {
        return failures, err
    }

    // Phase 3: Write outbox (only if changes detected)
    if len(events) > 0 {
        if err := s.cdc.WriteOutbox(ctx, tx, events); err != nil {
            return nil, classifyError(fmt.Errorf("CDC write outbox: %w", err))
        }
    }

    return nil, tx.Commit(ctx)
}
```

### Step 6: Metrics and observability

**In `CDC.DetectChanges`** — log + metrics:

```go
c.logger.WithFields(map[string]interface{}{
    "batch_size":      len(records),
    "cdc_created":     createdCount,
    "cdc_updated":     updatedCount,
    "cdc_unchanged":   unchangedCount,
    "cdc_fetch_ms":    fetchDuration.Milliseconds(),
    "cdc_classify_ms": classifyDuration.Milliseconds(),
}).Info("CDC change detection completed")
```

**In `CDC.WriteOutbox`** — log + metrics:

```go
c.logger.WithFields(map[string]interface{}{
    "event_count":   len(events),
    "cdc_outbox_ms": duration.Milliseconds(),
}).Debug("CDC outbox write")
```

**OTel metrics** (via existing `telemetry.Metrics`):

- Counter: `sink.cdc.events` with attribute `event_type=CREATED|UPDATED`
- Histogram: `sink.cdc.detect_duration_ms`
- Histogram: `sink.cdc.outbox_duration_ms`

### Step 7: Documentation and config updates

#### `docs/postgres-sink.md`

- **Architecture → Component Structure**: Add `cdc.go`, `cdc_test.go`, `cdc_integration_test.go`, `cdc_benchmark_test.go` to file listing
- **Architecture → Data Flow**: Update diagram to show CDC branch
- **Features → Core Capabilities**: Add CDC bullet point
- **Configuration**: New "CDC Settings" table documenting `cdc.enabled` (bool, default false)
- **Write Strategy**: Add "CDC-Enabled Write Strategy" subsection — transactional flow, outbox pattern, error semantics, single-writer assumption
- **Telemetry → Metrics**: Add CDC-specific metrics
- **Performance Tuning**: Add note about CDC overhead (3–4 extra RTs)
- **Testing**: Add CDC test cases to listing

#### `examples/vusion-to-postgres.yaml`

Add CDC config block (disabled by default) under `sink.postgres`:

```yaml
    # CDC (Change Data Capture) — detects CREATED/UPDATED records
    # and writes events to the event_outbox table atomically.
    # Requires event_outbox table to exist (see database migrations).
    cdc:
      enabled: false
```

#### `config-docker-test.yaml`

Add CDC config block (enabled for testing) under `sink.postgres`:

```yaml
    # CDC enabled for integration testing
    cdc:
      enabled: true
```

---

## Verification

### Unit tests (`cdc_test.go`) — pure functions, no DB

Table-driven:

- `TestBuildEntityKey` — single/composite keys, nil values
- `TestBuildFetchQuery` — correct SQL with `::TEXT` casts + args for 1 and N records
- `TestClassifyAndDiff_Created` — new record → CREATED with full payload (excluding conflict keys, including audit cols)
- `TestClassifyAndDiff_Updated` — changed fields → UPDATED with diff + flat audit columns
- `TestClassifyAndDiff_Unchanged` — identical → no event
- `TestClassifyAndDiff_AuditColumnsExcluded` — audit col changes ignored in comparison
- `TestClassifyAndDiff_ConflictKeysExcluded` — conflict keys excluded from comparison and payloads
- `TestClassifyAndDiff_TypeNormalization` — `float64(42)` normalized to `"42"` matches DB `"42"`
- `TestNormalizeValue` — all types: string, float64 (whole + decimal), bool, []any, nil, time strings
- `TestBuildOutboxInsert` — correct SQL, JSON marshaling
- `TestGroupByEntityType` — mixed types grouped correctly, entity types not in `entity.ConflictKeys` skipped

### Integration tests (`cdc_integration_test.go`) — real Postgres

Reuse shared testcontainer from existing `TestMain`:

- **New record → CREATED**: upsert new record → outbox has CREATED event with full snapshot
- **Changed record → UPDATED**: insert, then upsert changed → outbox has UPDATED event with diff + audit cols as flat values
- **Unchanged record → no event**: insert, upsert same → no outbox entry
- **CDC disabled → no overhead**: `cdc.enabled=false` → no outbox writes, no transaction
- **Mixed batch**: multiple entity types → correct events per type
- **Atomicity**: upsert fails mid-batch → no outbox events written (rollback)
- **Transient error during CDC → retry succeeds**: trigger simulated serialization error on first attempt, verify second attempt commits and outbox events are written
- **Permanent error during CDC → fail fast**: trigger CHECK constraint violation, verify first failing record stored in `records_with_errors`, error propagated via `Ack`

### Benchmark tests (`cdc_benchmark_test.go`) — real Postgres

Compare against real testcontainer:

- `BenchmarkExecuteBatch` — baseline (CDC disabled)
- `BenchmarkExecuteBatchWithCDC_AllNew` — worst case (all CREATED)
- `BenchmarkExecuteBatchWithCDC_AllUnchanged` — best case (no events)
- `BenchmarkExecuteBatchWithCDC_Mixed` — 10% changed

Batch sizes: 10, 50, 100, 500. Report ns/op and allocs.

### Verification commands

1. `go build ./...`
2. `go test ./internal/sink/postgres/... -v -short` — unit tests
3. `go test ./internal/sink/postgres/... -v -run Integration` — integration tests
4. `go test ./internal/sink/postgres/... -bench=. -benchmem -run=^$` — benchmarks
5. `go test ./... -short` — full project (no regressions)
6. Review `docs/postgres-sink.md` diff for completeness
7. Verify `config-docker-test.yaml` loads correctly with CDC enabled

---

## Known issues

- **Timestamp format inconsistency in event payloads**: CDC event diffs show `"old"` values in Postgres TEXT format (`2024-10-04 08:31:38.879+00`) and `"new"` values in RFC3339 (`2024-10-04T08:31:38.879Z`). The comparison logic (`normalizeValue`) handles both correctly — no false diffs — but downstream consumers see mixed formats. Needs a broader timestamp standardization effort across the entire app (4 different formats in use). Plan to be created separately.

- **CDC overhead at batch_size=500**: +51% (mixed) to +100% (all new) latency overhead. Acceptable for current workloads (~4s extra on a full 240k-record sync). Documented in `docs/postgres-sink.md`. If it becomes a bottleneck, consider lowering batch size to 200-300, chunking outbox INSERT, or using COPY.

## Follow-up tasks (post-CDC)

- **Standardize timestamp formats**: Unify the 4 timestamp representations (RFC3339 no millis, ISO 8601 with millis, `time.Time`, Postgres TEXT) to ISO 8601 with fractional seconds everywhere. Fixes the event payload inconsistency above. Requires its own plan.
- **Remove YAML `ConflictKeys` duplication**: Have the upsert builder read from `entity.ConflictKeys` instead of `TableConfig.ConflictKeys`. Eliminates divergence risk and simplifies config.
- **esl-common tag**: After CDC is validated in practice, create a new tag (e.g. `v0.2.0`) and update `go.mod` to reference it instead of a commit hash.
