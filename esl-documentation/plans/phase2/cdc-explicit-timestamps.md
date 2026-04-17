# Plan: phase2-cdc-explicit-timestamps

**Scope:** `datapipeline` project — explicit audit timestamps for entity/outbox consistency
**Depends on:** phase2-cdc-datapipeline (4c), refactor-outbox-uuid-primary-key (6b)
**Status:** Done (2026-04-10, commit 94bbd83)

## Problem

`created_at` and `last_updated_at` are absent from CDC outbox payloads because:

1. Both columns are set by the database — `created_at` via `DEFAULT NOW()` in the DDL, `last_updated_at` via `"last_updated_at" = NOW()` in the upsert SET clause
2. Neither column is in `record.RawData` (the source data never includes them)
3. The CDC fetch query only SELECTs columns from `RawData` keys — so these columns aren't fetched from existing rows either
4. The `auditColumns` mechanism in `classifyAndDiff` (lines 458-461) tries to read them from `RawData`, which always misses

The entire `auditColumns` code path is effectively dead.

## Solution

Generate a single `batchTimestamp` per batch and use it explicitly for both the upsert and the outbox payload. This guarantees the entity table and outbox have identical timestamp values.

### Approach: inject timestamps into RawData

Inject `created_at` and `last_updated_at` into each record's `RawData` before query preparation. This leverages the existing column-based query builder:

- `created_at`: set in INSERT VALUES, **excluded from UPDATE SET** (preserves original on conflict)
- `last_updated_at`: set in INSERT VALUES, included in UPDATE SET via `EXCLUDED."last_updated_at"`

The hardcoded `"last_updated_at" = NOW()` in `query.go` is removed — the injected value flows through `EXCLUDED` instead.

Injection happens **before** both CDC detection and upsert building, so:

- CDC fetch query automatically includes both columns (derived from RawData keys)
- `classifyAndDiff` diff exclusion for audit columns becomes live (was previously dead)
- CREATED event payloads naturally include both timestamps
- UPDATED event payloads get `last_updated_at` from `RawData` and `created_at` from the existing row

### Why inject for all paths (not just CDC)

Injecting timestamps regardless of CDC flag ensures:

- Deterministic, reproducible timestamps (no reliance on DB `NOW()`)
- Consistent query builder behavior — no conditional logic for "has timestamps" vs "doesn't"
- Schema plan cache doesn't thrash between CDC and non-CDC column sets
- If CDC is enabled later, existing behavior doesn't change

## Design decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Timestamp injection scope | All paths (CDC + non-CDC) | Consistent behavior, no conditional branches in query builder |
| `created_at` in UPDATE SET | Excluded | Only set on INSERT; existing records keep their original `created_at` |
| `last_updated_at` in UPDATE SET | Via `EXCLUDED` | Replaces hardcoded `NOW()` — uses same value as INSERT attempt |
| `created_at` for UPDATED events | From existing row | The original creation time, not the current batch timestamp |
| `last_updated_at` for UPDATED events | From `RawData` (injected batch timestamp) | Matches what the upsert SET clause will write |
| `batchTimestamp` generation | `time.Now().UTC()` in `executeBatch` | One value per batch, shared across upsert and outbox |
| `OccurredAt` for events | `batchTimestamp` | Previously used a separate `time.Now()` inside `classifyAndDiff`; now aligned with the upsert timestamp |

## Files to modify

| File | Change |
|------|--------|
| `internal/sink/postgres/write_batch.go` | Generate `batchTimestamp` in `executeBatch`; inject into records; pass to `executeBatchWithCDC` |
| `internal/sink/postgres/query.go` | Exclude `created_at` from UPDATE SET; remove hardcoded `NOW()` for `last_updated_at` |
| `internal/sink/postgres/cdc.go` | `DetectChanges` + `classifyAndDiff` accept `batchTimestamp`; UPDATED events use existing row's `created_at` |
| `internal/sink/postgres/cdc_test.go` | Update unit tests: add timestamps to RawData, verify audit columns in payloads |
| `internal/sink/postgres/cdc_integration_test.go` | Remove artificial `created_at` from `makeStoreRecord`; assert both timestamps in CREATED + UPDATED payloads |
| `internal/sink/postgres/query_test.go` | Update expected SQL (no `NOW()`, `created_at` excluded from SET) |

No new files.

## Step-by-step implementation

### Step 1: Timestamp injection in write_batch.go

**File: `internal/sink/postgres/write_batch.go`**

Add helper to inject audit timestamps into records:

```go
// injectAuditTimestamps sets created_at and last_updated_at on each record's
// RawData so the upsert and outbox use the same deterministic value.
func injectAuditTimestamps(records []*models.Record, ts time.Time) {
    for _, r := range records {
        r.RawData[ColCreatedAt] = ts
        r.RawData[ColLastUpdatedAt] = ts
    }
}
```

Modify `executeBatch` to generate `batchTimestamp` and inject before the CDC check:

```go
func (s *PostgresSink) executeBatch(
    ctx context.Context,
    records []*models.Record,
) ([]recordFailure, error) {
    batchTimestamp := time.Now().UTC()
    injectAuditTimestamps(records, batchTimestamp)

    if s.cdc != nil {
        return s.executeBatchWithCDC(ctx, records, batchTimestamp)
    }
    // ... non-CDC path unchanged
}
```

Modify `executeBatchWithCDC` to accept `batchTimestamp` and pass it to `DetectChanges`:

```go
func (s *PostgresSink) executeBatchWithCDC(
    ctx context.Context,
    records []*models.Record,
    batchTimestamp time.Time,
) ([]recordFailure, error) {
    // ...
    events, err := s.cdc.DetectChanges(
        ctx, tx, records, s.config.Tables, batchTimestamp,
    )
    // ... phases 2 and 3 unchanged
}
```

### Step 2: Query builder — exclude `created_at` from UPDATE SET, remove `NOW()`

**File: `internal/sink/postgres/query.go`**

In `buildUpsertQueryString`, modify the update fields logic:

```go
// Build update clause — exclude conflict keys AND created_at
if len(updateFields) == 0 {
    excludeFromUpdate := make(map[string]bool, len(conflictKeys)+1)
    for _, key := range conflictKeys {
        excludeFromUpdate[key] = true
    }
    excludeFromUpdate[ColCreatedAt] = true // only set on INSERT

    updateFields = make([]string, 0, len(columns))
    for _, col := range columns {
        if !excludeFromUpdate[col] {
            updateFields = append(updateFields, col)
        }
    }
}
```

Build SET clause without the hardcoded `NOW()` — `last_updated_at` now flows through `EXCLUDED`:

```go
updateParts := make([]string, 0, len(updateFields))
for _, field := range updateFields {
    updateParts = append(
        updateParts,
        fmt.Sprintf("\"%s\" = EXCLUDED.\"%s\"", field, field),
    )
}
// Removed: fmt.Sprintf("\"%s\" = NOW()", ColLastUpdatedAt)
```

**Result:** The generated SQL changes from:

```sql
INSERT INTO table (col1, col2) VALUES ($1, $2)
ON CONFLICT (pk) DO UPDATE SET
  "col1" = EXCLUDED."col1",
  "last_updated_at" = NOW()
```

To:

```sql
INSERT INTO table (col1, col2, created_at, last_updated_at) VALUES ($1, $2, $3, $4)
ON CONFLICT (pk) DO UPDATE SET
  "col1" = EXCLUDED."col1",
  "last_updated_at" = EXCLUDED."last_updated_at"
```

- `created_at` in INSERT but **not** in SET — only set on new rows
- `last_updated_at` in both INSERT and SET — always set to the batch timestamp

### Step 3: CDC — accept batchTimestamp, fix UPDATED audit columns

**File: `internal/sink/postgres/cdc.go`**

Modify `DetectChanges` signature:

```go
func (c *CDC) DetectChanges(
    ctx context.Context,
    tx pgx.Tx,
    records []*models.Record,
    tables map[string]TableConfig,
    batchTimestamp time.Time,
) ([]event.ChangeEvent, error) {
    // ...
    events := classifyAndDiff(
        existing, group.records,
        entityType, group.conflictKeys,
        batchTimestamp,
    )
    // ...
}
```

Modify `classifyAndDiff` — accept `batchTimestamp`, replace `time.Now()`, fix UPDATED audit handling:

```go
func classifyAndDiff(
    existing map[string]map[string]any,
    records []*models.Record,
    entityType string,
    conflictKeys []string,
    batchTimestamp time.Time,
) []event.ChangeEvent {
    // ...

    for _, record := range records {
        // CREATED path: payload includes all non-conflict-key fields from RawData.
        // created_at and last_updated_at are now in RawData (injected),
        // so they're included automatically. No changes needed.

        // UPDATED path: replace the generic auditColumns loop.
        // created_at: from existing row (original creation time, not batch timestamp)
        // last_updated_at: from RawData (the injected batch timestamp)
        if val, ok := existingRow[ColCreatedAt]; ok {
            diff[ColCreatedAt] = normalizePayloadValue(val)
        }
        if val, ok := record.RawData[ColLastUpdatedAt]; ok {
            diff[ColLastUpdatedAt] = normalizePayloadValue(val)
        }

        events = append(events, event.ChangeEvent{
            // ...
            OccurredAt: batchTimestamp, // was: time.Now().UTC()
        })
    }
}
```

**Key difference from current code:** The generic `for col := range auditColumns` loop is replaced with explicit per-column logic because `created_at` and `last_updated_at` come from different sources in UPDATED events.

**Why this works:**

- The fetch query now includes `created_at` and `last_updated_at` (they're in RawData keys, which drive column selection on line 65). So `existingRow` contains the real `created_at` as a TEXT string.
- `normalizePayloadValue` parses the Postgres TEXT timestamp into `time.Time`, so JSON marshaling produces RFC3339Nano.
- `auditColumns` exclusion in the diff comparison (line 441) is now live — prevents `created_at`/`last_updated_at` changes from triggering false UPDATED events.

### Step 4: Update tests

#### Unit tests (`cdc_test.go`)

- All test record `RawData` maps must include `created_at` and `last_updated_at` (reflecting real post-injection state)
- `TestClassifyAndDiff_Updated`: verify `created_at` comes from existing row value, `last_updated_at` matches the passed `batchTimestamp`
- `TestClassifyAndDiff_Created`: verify both timestamps from RawData (the injected values)
- `TestClassifyAndDiff_AuditColumnsExcluded`: now actually exercises the exclusion (was dead code before)
- New: `TestInjectAuditTimestamps` — verifies both columns are set on all records
- Update all `classifyAndDiff` call sites to pass `batchTimestamp` parameter

#### Query tests (`query_test.go`)

- Rename "includes last_updated_at NOW()" test to reflect new behavior
- Add `created_at` and `last_updated_at` to test input columns
- Assert `created_at` appears in INSERT but **not** in SET clause
- Assert `last_updated_at` uses `EXCLUDED` not `NOW()`

#### Integration tests (`cdc_integration_test.go`)

- Remove `"created_at": time.Now()` from `makeStoreRecord` — it's now injected by the sink
- CREATED event test: assert payload contains both `created_at` and `last_updated_at`
- UPDATED event test: assert payload contains `created_at` (matching the original INSERT) and `last_updated_at`
- Assert entity table `created_at` matches outbox payload `created_at` for CREATED events

## Verification

```bash
go build ./...
go test ./internal/sink/postgres/... -v -short        # unit tests
go test ./internal/sink/postgres/... -v -run Integration  # integration tests
go test ./... -short                                    # full project (no regressions)
```
