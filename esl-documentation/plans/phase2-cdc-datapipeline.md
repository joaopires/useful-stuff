# Plan: phase2-cdc-datapipeline

**Scope:** `datapipeline` project — CDC detection in the sink
**Depends on:** shared package (esl-common latest commit on main), database migrations (V1.0.0.15–17)
**Status:** Prerequisites in progress (1 of 3 done)

## Prerequisite tasks

### Refactor: replace hardcoded entity strings with `entity.EntityType`

The datapipeline currently uses hardcoded `"store"`, `"product"`, `"label"`, `"accesspoint"` strings throughout. As part of the CDC work (which introduces the esl-common dependency anyway), replace these with `entity.EntityType` constants:

- **`internal/connector/vusion/vusion.go`** — `createRecord()` calls pass string literals for entity type → use `entity.Store`, `entity.Product`, etc.
- **`internal/transformer/normalizer/normalizer.go`** — strategy map keys are strings → use `entity.EntityType` keys
- **`internal/sink/postgres/` config/tests** — `TableConfig` map keys and test fixtures → use `entity.EntityType`

This ensures type safety and a single source of truth for entity type values across both datapipeline and event-publisher.

### ~~Code quality: add golangci-lint config~~ ✅ DONE (2026-03-31, commit a62bdd4)

- Added `.golangci.yml` (v2 format) with: `errcheck`, `gosec`, `staticcheck`, `ineffassign`, and `gofumpt` formatter
- Added `GOLANGCI_LINT_VERSION=v2.8.0` variable and `install-lint` target to the Makefile
- Updated `lint` target to depend on `install-lint` and use `--config=.golangci.yml`
- Fixed 59 lint findings across 47 files, `make lint` passes with 0 issues

### Refactor: adopt `postgres` package from esl-common

esl-common now provides a `postgres` package with shared pool creation and error classification. As part of adopting the updated esl-common dependency:

- **Pool creation** — replace duplicated `pgxpool` setup in the sink builder and state store with `postgres.NewPool`. Each service maps its own config format to `postgres.PoolConfig`.
- **Error classification** — refactor `internal/sink/postgres/errors.go` (`classifyError`) to delegate to `postgres.ClassifyError` and `postgres.IsTransient`. App-specific behavior (failed record storage, batch error joining, `records_with_errors` table writes) stays in the datapipeline.
- **Fix `classifyJoined` retry logic** — the current implementation treats any unclassified error as transient (if not all errors are permanent, the joined error is wrapped as transient). This causes unrecognized PG errors (e.g. `42703` — undefined column) to burn through retries with backoff instead of failing fast. Replace with: retry only when `postgres.IsTransient` returns true; unclassified errors should not be retried.

### Fix integration test table schemas

The shared `createTestTable` helper in `postgres_integration_test.go` creates tables without the `last_updated_at` column, but `query.go` hardcodes `"last_updated_at" = NOW()` in the upsert ON CONFLICT clause. PostgreSQL validates the full statement at parse time, so even non-conflicting INSERTs fail with `42703`. Combined with the `classifyJoined` bug above, this makes every test that uses `createTestTable` retry to exhaustion (~7s per test, ~140s for ConnectionPool).

- Add `last_updated_at TIMESTAMP` to `createTestTable` helper
- Add the same column to custom table creation in `TestPostgresSink_Integration_BatchContinuesAfterPartialFailure`

---

## CDC Implementation

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

**Error semantics**: CDC path rolls back entire batch on any failure (vs current per-record continuation). Required because partial upserts + partial outbox is invalid.

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
// and classifies each record as CREATED, MODIFIED, or unchanged.
func (c *CDC) DetectChanges(
    ctx context.Context,
    tx pgx.Tx,
    records []*models.OutputRecord,
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

The upsert batch-building logic is currently inlined in `executeBatch`. Extract it so both CDC and non-CDC paths reuse it:

```go
// buildUpsertBatch builds a pgx.Batch with upsert queries for all records.
// Used by both executeBatch (non-CDC) and executeBatchWithCDC.
func (s *PostgresSink) buildUpsertBatch(
    records []*models.OutputRecord,
) (*pgx.Batch, error)
```

#### Thin orchestrator (ISP, DIP)

`executeBatchWithCDC` is a small coordinator — it owns the transaction lifecycle and delegates each step:

```go
func (s *PostgresSink) executeBatchWithCDC(ctx, records) error {
    tx, _ := s.pool.Begin(ctx)
    defer tx.Rollback(ctx)

    events, _ := s.cdc.DetectChanges(ctx, tx, records, s.config.Tables)

    batch, _ := s.buildUpsertBatch(records)     // DRY: shared with non-CDC
    // ... send batch on tx, fail-fast on error

    if len(events) > 0 {
        s.cdc.WriteOutbox(ctx, tx, events)
    }
    return tx.Commit(ctx)
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
    records []*models.OutputRecord,
    tables map[string]TableConfig,
) map[string]entityGroup

type entityGroup struct {
    tableName    string
    conflictKeys []string
    records      []*models.OutputRecord
}
```

**`buildEntityKey`** — builds lookup key + JSON-serializable key map:

```go
func buildEntityKey(data map[string]any, conflictKeys []string) (string, map[string]string)
```

- Lookup string: values joined with `"|"` (e.g. `"RC001|S001|P001"`)
- Key map: `{"retail_chain_id": "RC001", ...}`
- Uses `fmt.Sprintf("%v", val)` to normalize

**`buildFetchQuery`** — builds SELECT with composite PK IN clause:

```go
func buildFetchQuery(
    schema, tableName string,
    conflictKeys []string,
    records []*models.OutputRecord,
) (string, []any)
```

Generates: `SELECT * FROM schema.table WHERE (pk1, pk2) IN (($1,$2), ($3,$4), ...)`

**`classifyAndDiff`** — compares incoming vs existing, returns change events:

```go
func classifyAndDiff(
    existing map[string]map[string]any,
    records []*models.OutputRecord,
    entityType string,
    conflictKeys []string,
) []event.ChangeEvent
```

- Key not in existing → `CREATED` (payload = full record data, excluding audit cols)
- Key in existing, fields differ → `MODIFIED` (payload = `{"field": {"old": X, "new": Y}}`)
- Identical → skip
- Comparison via `normalizeValue(v) string` — handles int/int64, float/float64, time.Time formatting
- Audit columns (`created_at`, `last_updated_at`) excluded from comparison and CREATED payloads

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
        query, args := buildFetchQuery(c.schema, group.tableName, group.conflictKeys, group.records)
        rows, _ := tx.Query(ctx, query, args...)
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

**Extract `buildUpsertBatch`** from `executeBatch` (DRY):

```go
func (s *PostgresSink) buildUpsertBatch(records []*models.OutputRecord) (*pgx.Batch, error) {
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

**Refactor `executeBatch`** to use `buildUpsertBatch` and dispatch CDC:

```go
func (s *PostgresSink) executeBatch(ctx, records) error {
    if s.cdc != nil {
        return s.executeBatchWithCDC(ctx, records)
    }

    prepareStart := time.Now()
    batch, err := s.buildUpsertBatch(records)  // extracted
    if err != nil {
        return err
    }
    prepareDuration := time.Since(prepareStart)

    // ... rest unchanged (SendBatch, per-record error handling, timing)
}
```

**Add `executeBatchWithCDC`**:

```go
func (s *PostgresSink) executeBatchWithCDC(ctx, records) error {
    tx, err := s.pool.Begin(ctx)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback(ctx)

    // Phase 1: Detect changes (SELECT + classify)
    events, err := s.cdc.DetectChanges(ctx, tx, records, s.config.Tables)
    if err != nil {
        return fmt.Errorf("CDC detect changes: %w", err)
    }

    // Phase 2: Execute upserts (fail-fast, rollback on any error)
    batch, err := s.buildUpsertBatch(records)
    if err != nil {
        return err
    }
    br := tx.SendBatch(ctx, batch)
    for _, record := range records {
        if _, err := br.Exec(); err != nil {
            br.Close()
            return fmt.Errorf("upsert record %s: %w", record.ID, err)
        }
    }
    br.Close()

    // Phase 3: Write outbox (only if changes detected)
    if len(events) > 0 {
        if err := s.cdc.WriteOutbox(ctx, tx, events); err != nil {
            return fmt.Errorf("CDC write outbox: %w", err)
        }
    }

    return tx.Commit(ctx)
}
```

### Step 6: Metrics and observability

**In `CDC.DetectChanges`** — log + metrics:

```go
s.logger.WithFields(map[string]interface{}{
    "batch_size":      len(records),
    "cdc_created":     createdCount,
    "cdc_modified":    modifiedCount,
    "cdc_unchanged":   unchangedCount,
    "cdc_fetch_ms":    fetchDuration.Milliseconds(),
    "cdc_classify_ms": classifyDuration.Milliseconds(),
}).Info("CDC change detection completed")
```

**In `CDC.WriteOutbox`** — log + metrics:

```go
s.logger.DebugWithFields("CDC outbox write", map[string]interface{}{
    "event_count":   len(events),
    "cdc_outbox_ms": duration.Milliseconds(),
})
```

**OTel metrics** (via existing `telemetry.Metrics`):

- Counter: `sink.cdc.events` with attribute `event_type=CREATED|MODIFIED`
- Histogram: `sink.cdc.detect_duration_ms`
- Histogram: `sink.cdc.outbox_duration_ms`

### Step 7: Documentation and config updates

#### `docs/postgres-sink.md`

- **Architecture → Component Structure**: Add `cdc.go`, `cdc_test.go`, `cdc_integration_test.go`, `cdc_benchmark_test.go` to file listing
- **Architecture → Data Flow**: Update diagram to show CDC branch
- **Features → Core Capabilities**: Add CDC bullet point
- **Configuration**: New "CDC Settings" table documenting `cdc.enabled` (bool, default false)
- **Write Strategy**: Add "CDC-Enabled Write Strategy" subsection — transactional flow, outbox pattern, error semantics
- **Telemetry → Metrics**: Add CDC-specific metrics
- **Performance Tuning**: Add note about CDC overhead (3–4 extra RTs)
- **Testing**: Add CDC test cases to listing

#### `examples/vusion-to-postgres.yaml`

Add CDC config block (disabled by default) under `sink.postgres`:

```yaml
    # CDC (Change Data Capture) — detects CREATED/MODIFIED records
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
- `TestBuildFetchQuery` — correct SQL + args for 1 and N records
- `TestClassifyAndDiff_Created` — new record → CREATED with full payload
- `TestClassifyAndDiff_Modified` — changed fields → MODIFIED with diff
- `TestClassifyAndDiff_Unchanged` — identical → no event
- `TestClassifyAndDiff_AuditColumnsExcluded` — audit col changes ignored
- `TestClassifyAndDiff_TypeNormalization` — int vs int64
- `TestBuildOutboxInsert` — correct SQL, JSON marshaling
- `TestGroupByEntityType` — mixed types grouped correctly

### Integration tests (`cdc_integration_test.go`) — real Postgres

Reuse shared testcontainer from existing `TestMain`:

- **New record → CREATED**: upsert new record → outbox has CREATED event with full snapshot
- **Changed record → MODIFIED**: insert, then upsert changed → outbox has MODIFIED event with diff
- **Unchanged record → no event**: insert, upsert same → no outbox entry
- **CDC disabled → no overhead**: `cdc.enabled=false` → no outbox writes, no transaction
- **Mixed batch**: multiple entity types → correct events per type
- **Atomicity**: upsert fails mid-batch → no outbox events written (rollback)

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

## Post-implementation note

After the datapipeline implementation is complete and the esl-common code has been validated in practice, check whether a new esl-common tag (e.g. `v0.2.0`) should be created and referenced in `go.mod` instead of a commit hash.
