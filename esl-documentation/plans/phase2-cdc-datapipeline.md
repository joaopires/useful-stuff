# Plan: phase2-cdc-datapipeline

**Scope:** `datapipeline` project — CDC detection in the sink
**Depends on:** shared package, database migrations

## Critical files to modify

- `internal/sink/postgres/write_batch.go` — `executeBatch()` flow
- `internal/sink/postgres/postgres.go` — `DBPool` interface
- `internal/sink/postgres/config.go` — CDC config
- `internal/sink/postgres/builder.go` — wire CDC config

## New files

- `internal/sink/postgres/cdc.go` — CDC module

## 1. Config: add CDC flag

**File: `internal/sink/postgres/config.go`**

```go
type CDCConfig struct {
    Enabled bool `mapstructure:"enabled"`
}
```

Add `CDC CDCConfig` field to `Config` struct.

## 2. DBPool interface: add Begin

**File: `internal/sink/postgres/postgres.go`**

Add `Begin(ctx context.Context) (pgx.Tx, error)` to `DBPool` interface. pgxpool.Pool already implements it.

## 3. CDC module

**New file: `internal/sink/postgres/cdc.go`**

Functions:

- `fetchExistingRecords(ctx, tx, schema, tableName, conflictKeys, records) map[string]map[string]any`
  - Builds: `SELECT * FROM esl.{table} WHERE (pk1, pk2, pk3) IN (($1,$2,$3), ($4,$5,$6), ...)`
  - Returns map keyed by composite PK string (e.g. `"RC001|S001|P001"`)

- `classifyAndDiff(existing map, incoming []OutputRecord, conflictKeys, auditCols []string) []ChangeEvent`
  - For each incoming record:
    - Key not in existing → CREATED (payload = full record)
    - Key in existing, fields differ → MODIFIED (payload = changed fields only, as `{"field": {"old": X, "new": Y}}`)
    - Key in existing, identical → skip

- `buildOutboxBatch(schema string, events []ChangeEvent) *pgx.Batch`
  - Generates: `INSERT INTO esl.event_outbox (event_type, entity_type, entity_key, payload) VALUES ($1, $2, $3, $4)`

- `buildEntityKey(record map[string]any, conflictKeys []string) (string, map[string]string)`
  - Returns both the lookup string and the JSON-serializable key map

## 4. Batch execution: transactional CDC flow

**File: `internal/sink/postgres/write_batch.go`**

When `cdc.enabled`:

1. `tx, _ := pool.Begin(ctx)` — start transaction
2. `existing := fetchExistingRecords(ctx, tx, ...)` — pre-fetch current state
3. `events := classifyAndDiff(existing, records, ...)` — classify + compute diffs
4. Build upsert `pgx.Batch` (same SQL as today, no query changes)
5. `tx.SendBatch()` → process with `br.Exec()` as today
6. If events exist: `buildOutboxBatch(events)` → `tx.SendBatch()`
7. `tx.Commit()`

When `cdc.enabled = false`: existing behavior, no transaction wrapper.

## Verification

- **Unit tests:** `cdc_test.go` — classifyAndDiff logic, fetchExistingRecords query building, outbox batch building
- **Integration tests (testcontainers):** `cdc_integration_test.go`
  - Insert new record → verify outbox has CREATED event with full snapshot
  - Upsert changed record → verify outbox has MODIFIED event with diff
  - Upsert unchanged record → verify no outbox entry
  - CDC disabled → verify no outbox writes, no transaction overhead
- **Existing tests:** `go test ./...` must still pass
