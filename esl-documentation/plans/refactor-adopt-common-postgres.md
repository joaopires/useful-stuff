# Plan: refactor-adopt-common-postgres

**Scope:** datapipeline — adopt esl-common `postgres` package (pool creation + error classification)
**Depends on:** esl-common postgres package (step 1b of master plan, already done), refactor-entity-type-aliases (adds esl-common to go.mod)
**Status:** Not started

## Context

esl-common provides a `postgres` package with `NewPool` (shared pool creation) and `ClassifyError`/`IsTransient` (error classification). The datapipeline currently duplicates this logic in two places (sink builder, state store) and has a local `classifyError` with a retry bug.

## Part 1: Replace duplicated pool creation

### Current state

Both the sink builder ([builder.go:49-93](internal/sink/postgres/builder.go#L49-L93)) and state store ([postgres_state.go:86-126](internal/state/postgres/postgres_state.go#L86-L126)) have ~30 lines of identical pool setup:

1. Parse connection string → `pgxpool.ParseConfig`
2. Apply pool settings (MaxConns, MinConns, lifetimes, etc.)
3. Set RuntimeParams (application_name)
4. Create pool with timeout context
5. Ping to verify

`postgres.NewPool` does all of this from a `PoolConfig` struct.

### Design

Add a `PoolConfig()` method to the existing `ConnectionConfig` that maps local config fields to `postgres.PoolConfig`. Each call site replaces ~30 lines with a 2-line call.

`ConnectionConfig` itself stays — it handles Viper/mapstructure deserialization and carries the `Schema` field (which `PoolConfig` doesn't have). `ConnectionString()` stays too — integration tests use it directly for `sql.Open`.

### Changes

**`internal/postgres/connection.go`** — add method:

```go
import commonpg "github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common/postgres"

func (c *ConnectionConfig) PoolConfig() commonpg.PoolConfig {
    return commonpg.PoolConfig{
        Host:              c.Host,
        Port:              c.Port,
        Database:          c.Database,
        Username:          c.Username,
        Password:          c.Password,
        SSLMode:           c.SSLMode,
        MaxConns:          int32(c.MaxConnections),
        MinConns:          int32(c.MinConnections),
        MaxConnLifetime:   c.MaxConnLifetime,
        MaxConnIdleTime:   c.MaxConnIdleTime,
        HealthCheckPeriod: c.HealthCheckPeriod,
        ConnectTimeout:    c.ConnectTimeout,
    }
}
```

**`internal/sink/postgres/builder.go`** — replace lines 56-93:

```go
// Before: 30+ lines of pgxpool setup
poolConfig, err := pgxpool.ParseConfig(b.config.ConnectionString())
// ... configure pool, set RuntimeParams, create, ping

// After:
cfg := b.config.PoolConfig()
cfg.ApplicationName = b.config.ApplicationName
pool, err := commonpg.NewPool(context.Background(), cfg)
if err != nil {
    return nil, fmt.Errorf("failed to create connection pool: %w", err)
}
```

Remove `pgxpool` import (no longer directly used).

**`internal/state/postgres/postgres_state.go`** — replace lines 86-126 (`New` function):

```go
// Before: 30+ lines of pgxpool setup
poolConfig, err := pgxpool.ParseConfig(config.ConnectionString())
// ... configure pool, set RuntimeParams, create, ping

// After:
cfg := config.PoolConfig()
cfg.ApplicationName = "esl-state-store"
pool, err := commonpg.NewPool(context.Background(), cfg)
if err != nil {
    return nil, fmt.Errorf("failed to create connection pool: %w", err)
}

store, err := NewWithPool(pool, config)
if err != nil {
    pool.Close()
    return nil, err
}
return store, nil
```

Remove `pgxpool` import (no longer directly used).

---

## Part 2: Replace local error classification

### Current state

`classifyError` in [errors.go:53-77](internal/sink/postgres/errors.go#L53-L77) maps PG error codes to the local `errs.NewTransient`/`errs.NewPermanent` wrappers. esl-common's `postgres.IsTransient` and `postgres.ClassifyError` now handle the same PG codes plus more (foreign key, check violations, network errors).

The local function is used in two places:
- [write_batch.go:139](internal/sink/postgres/write_batch.go#L139) — per-record error in `executeBatch`
- [write_batch.go:175](internal/sink/postgres/write_batch.go#L175) — per-record error in `execOne`

The `classifyJoined` function at [errors.go:83-107](internal/sink/postgres/errors.go#L83-L107) is used at [write_batch.go:157](internal/sink/postgres/write_batch.go#L157) to classify the batch-level joined error.

### Design

Rewrite `classifyError` to delegate to `postgres.IsTransient`:

```go
func classifyError(err error) error {
    if err == nil {
        return nil
    }
    if commonpg.IsTransient(err) {
        return errs.NewTransient(err, "transient database error")
    }
    // ClassifyError wraps recognized PG errors with sentinel errors.
    // Non-transient recognized errors (unique violation, syntax error, etc.) are permanent.
    classified := commonpg.ClassifyError(err)
    if classified != err {
        return errs.NewPermanent(err, "permanent database error")
    }
    return err
}
```

This keeps the bridge to the local `errs` package (needed by the retry system) while eliminating the duplicated PG code mapping.

The `net.Error` and `pgconn` imports in errors.go are no longer needed — `IsTransient` handles both.

### Fix: classifyJoined retry logic

**Bug:** the current `classifyJoined` treats any batch that isn't all-permanent as transient. This means unrecognized PG errors (e.g. `42703` — undefined column) get retried with backoff when they should fail fast.

The retry system ([retry.go:57](internal/retry/retry.go#L57)) retries everything that isn't permanent or context-cancelled. So an unclassified (unwrapped) error from `classifyJoined` should NOT be wrapped as transient — it should be left as-is. But currently it IS wrapped as transient.

**Fix:** only mark as transient if at least one sub-error is actually transient:

```go
func classifyJoined(err error) error {
    if errs.IsPermanent(err) || errs.IsTransient(err) {
        return err
    }

    type unwrapper interface{ Unwrap() []error }
    uw, ok := err.(unwrapper)
    if !ok {
        return err
    }

    allPermanent := true
    hasTransient := false
    for _, e := range uw.Unwrap() {
        if errs.IsTransient(e) {
            hasTransient = true
        }
        if !errs.IsPermanent(e) {
            allPermanent = false
        }
    }

    if allPermanent {
        return errs.NewPermanent(err, "all records in batch permanently failed")
    }
    if hasTransient {
        return errs.NewTransient(err, "batch contains transient errors")
    }
    // Mixed: some permanent, some unclassified, none transient — don't retry.
    return errs.NewPermanent(err, "batch failed with non-retryable errors")
}
```

---

## Part 3: Fix integration test table schemas

### Current state

`createTestTable` in [postgres_integration_test.go:123-147](internal/sink/postgres/postgres_integration_test.go#L123-L147) creates tables with columns `(id, name, value, created_at)` but no `last_updated_at`. The upsert query in [query.go:133](internal/sink/postgres/query.go#L133) hardcodes `"last_updated_at" = NOW()` in the ON CONFLICT clause. PostgreSQL validates the full statement at parse time, so even non-conflicting INSERTs fail with `42703` (undefined column).

Combined with the `classifyJoined` bug, this makes affected tests retry to exhaustion (~7s per test).

The error_handling tests at lines 396 and 508 already include `last_updated_at` — they were fixed individually but the shared helper wasn't.

### Changes

**`internal/sink/postgres/postgres_integration_test.go`** — add column to `createTestTable`:

```go
// Before
CREATE TABLE IF NOT EXISTS %s (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255),
    value INTEGER,
    created_at TIMESTAMP
)

// After
CREATE TABLE IF NOT EXISTS %s (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255),
    value INTEGER,
    created_at TIMESTAMP,
    last_updated_at TIMESTAMP
)
```

**`internal/sink/postgres/error_handling_integration_test.go`** — add column to the two custom table creations that are missing it:

Line 313 (`TestPostgresSink_Integration_BatchContinuesAfterPartialFailure`):
```sql
-- Before
CREATE TABLE test_check_constraint (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255),
    value INTEGER CHECK (value >= 0),
    created_at TIMESTAMP
)

-- After
CREATE TABLE test_check_constraint (
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255),
    value INTEGER CHECK (value >= 0),
    created_at TIMESTAMP,
    last_updated_at TIMESTAMP
)
```

---

## Files to modify

| # | File | Change |
|---|------|--------|
| 1 | `internal/postgres/connection.go` | Add `PoolConfig()` method |
| 2 | `internal/sink/postgres/builder.go` | Replace pool setup with `commonpg.NewPool` |
| 3 | `internal/state/postgres/postgres_state.go` | Replace pool setup with `commonpg.NewPool` |
| 4 | `internal/sink/postgres/errors.go` | Rewrite `classifyError` + `classifyJoined` using esl-common |
| 5 | `internal/sink/postgres/postgres_integration_test.go` | Add `last_updated_at` to `createTestTable` |
| 6 | `internal/sink/postgres/error_handling_integration_test.go` | Add `last_updated_at` to custom table creation (line 313) |

## Verification

1. `go build ./...` — compiles
2. `go test ./internal/sink/postgres/... -v -short` — unit tests pass
3. `go test ./internal/state/postgres/... -v -short` — state store unit tests pass
4. `go test ./internal/sink/postgres/... -v -run Integration` — integration tests pass (and run faster without retry exhaustion)
5. `go test ./... -v -short` — full project, no regressions
6. `make lint` — no new lint findings
