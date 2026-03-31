# Plan: phase2-cdc-postgres-package

**Scope:** `esl-common` repository — new `postgres` package
**Depends on:** Nothing (esl-common already exists)

Add a `postgres` package to esl-go-commons that provides shared pool configuration, creation, and error classification. All app-specific logic (queries, models, tables, retry policies) stays in each service.

## What it provides

### `PoolConfig` struct

```go
type PoolConfig struct {
    Host              string
    Port              int
    Database          string
    Username          string
    Password          string
    SSLMode           string
    ApplicationName   string
    MaxConns          int32
    MinConns          int32
    MaxConnLifetime   time.Duration
    MaxConnIdleTime   time.Duration
    HealthCheckPeriod time.Duration
    ConnectTimeout    time.Duration
}
```

### `SetDefaults()`

| Field | Default |
|-------|---------|
| Port | 5432 |
| SSLMode | "disable" |
| MaxConns | 10 |
| MinConns | 2 |
| MaxConnLifetime | 1h |
| MaxConnIdleTime | 30m |
| HealthCheckPeriod | 1m |
| ConnectTimeout | 10s |

### `Validate() error`

Checks required fields (Host, Database, Username) and pool invariants (MinConns <= MaxConns, positive durations).

### `NewPool(ctx, PoolConfig) (*pgxpool.Pool, error)`

1. Build DSN (postgres:// URL format — handles special chars in passwords)
2. `pgxpool.ParseConfig(dsn)`
3. Apply pool settings (MaxConns, MinConns, lifetimes, health check)
4. Set `application_name` in RuntimeParams (if provided)
5. Create pool with connect timeout context
6. Ping to verify connectivity
7. Return pool or close-and-error

### Error classification

Exported sentinel errors for common PostgreSQL error codes:

```go
// Permanent errors — will not succeed on retry.
var (
    ErrUniqueViolation    = errors.New("unique constraint violation")     // 23505
    ErrNotNullViolation   = errors.New("not null constraint violation")   // 23502
    ErrForeignKeyViolation = errors.New("foreign key violation")          // 23503
    ErrCheckViolation     = errors.New("check constraint violation")      // 23514
    ErrSyntaxError        = errors.New("syntax error")                    // 42601
)

// Transient errors — may succeed on retry.
var (
    ErrDeadlock              = errors.New("deadlock detected")            // 40P01
    ErrSerializationFailure  = errors.New("serialization failure")        // 40001
    ErrAdminShutdown         = errors.New("admin shutdown")               // 57P01
    ErrCrashShutdown         = errors.New("crash shutdown")               // 57P02
    ErrCannotConnectNow      = errors.New("cannot connect now")           // 57P03
)
```

**`ClassifyError(err error) error`** — extracts `*pgconn.PgError`, wraps with the matching sentinel via `fmt.Errorf("%w: %s", sentinel, pgErr.Message)`. Returns the original error unchanged if it's not a `PgError`.

**`IsTransient(err error) bool`** — returns true for transient PG errors and `net.Error` (network failures). Consumers use this to decide retry behavior without inspecting codes themselves.

**`PgErrorCode(err error) string`** — extracts the PG error code string from an error chain, returns empty string if not a PgError. Useful for logging/metrics.

### Consumer usage

```go
err := tx.Exec(ctx, query, args...)
if err != nil {
    classified := postgres.ClassifyError(err)
    if postgres.IsTransient(classified) {
        // retry
    }
    if errors.Is(classified, postgres.ErrUniqueViolation) {
        // handle conflict
    }
}
```

The datapipeline's current `classifyError` in `internal/sink/postgres/errors.go` would delegate to the shared helpers. App-specific behavior (failed record storage, batch error joining, `records_with_errors` table writes) stays in the datapipeline.

## What it does NOT provide

- Queries, transactions, or SQL generation
- Table/entity models or schema awareness
- Config loading (YAML, env vars — each service owns this)
- Application-specific defaults (services override after `SetDefaults`)
- Retry policies or backoff logic (consumer decides)

## File layout

```
common/
├── entity/
├── event/
└── postgres/
    ├── pool.go         # PoolConfig + NewPool
    ├── pool_test.go    # Unit + integration tests for pool
    ├── errors.go       # Sentinel errors + ClassifyError + IsTransient
    └── errors_test.go  # Error classification tests
```

## Import path

```go
import "github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common/postgres"
```

## Dependency impact

Adds `github.com/jackc/pgx/v5` to esl-common's `go.mod`. This is a pure Go library (no cgo). Consumers that already use pgx (datapipeline, datafetch) get no new transitive dependencies.

## Consumer adoption

Each service maps its own config format to `PoolConfig` and calls `NewPool`:

**datapipeline** — replace duplicated pool creation in sink builder + state store with `postgres.NewPool`. Refactor `classifyError` to use shared `ClassifyError`/`IsTransient`. Part of step 4 (datapipeline CDC).

**event-publisher** — use `postgres.NewPool` and error helpers from the start. Part of step 6.

**datafetch** — can adopt independently (low priority, not blocking).

## Verification

### Unit tests

**`pool_test.go`:**
- `TestSetDefaults` — all defaults applied, explicit values preserved
- `TestValidate` — missing host/database/username errors, MinConns > MaxConns error
- `TestDSN` — correct URL format, special characters in password escaped

**`errors_test.go`:**
- `TestClassifyError_UniqueViolation` — 23505 → `ErrUniqueViolation`
- `TestClassifyError_Deadlock` — 40P01 → `ErrDeadlock`
- `TestClassifyError_NonPgError` — returns original error unchanged
- `TestIsTransient_PgErrors` — deadlock/serialization/shutdown → true
- `TestIsTransient_NetworkError` — `net.Error` → true
- `TestIsTransient_PermanentErrors` — constraint violations → false
- `TestPgErrorCode` — extracts code, returns empty for non-PgError

### Integration tests (`pool_test.go`)

Uses testcontainers (PostgreSQL):

- `TestNewPool` — creates pool, verifies connectivity
- `TestNewPoolInvalidCredentials` — returns error, no leaked pool
- `TestNewPoolApplicationName` — verify `application_name` visible via `pg_stat_activity`
