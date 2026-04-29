# CDC Batch — Identify Root-Cause Record vs. Collateral Peers

## Problem

When the Postgres sink runs with CDC enabled and a `pgx.SendBatch` fails on
one record (e.g. unique-constraint violation), the entire transaction rolls
back to preserve upsert/outbox atomicity. Today the sink reports a uniform
outcome for every record in the failing batch (`uniformOutcomes(records,
rolledBackErr(batchErr))`), so every row that lands in `records_with_errors`
carries the same wrapped error message — including the actual offender.

Operators currently have no clean way to distinguish the trigger from its
collateral peers. The only signal is parsing the record ID embedded in the
error_message string and matching it to the `record_id` column.

Reference: [`executeBatchWithCDC`](../../sonae/esl/datapipeline/internal/sink/postgres/write_batch.go)
(`internal/sink/postgres/write_batch.go:277`).

## Goal

Differentiate the actual culprit from rolled-back peers in
`records_with_errors` via a typed column, so operators can run queries like:

```sql
SELECT * FROM records_with_errors
WHERE run_id = $1 AND is_root_cause IS TRUE;
```

…to find true causes without parsing free-text error messages.

## Naming

Column name: **`is_root_cause`** (boolean, nullable).

| Scenario                          | `is_root_cause` |
|-----------------------------------|-----------------|
| Non-CDC failure (own implicit tx) | `true`          |
| CDC SendBatch — trigger record    | `true`          |
| CDC SendBatch — peer record       | `false`         |
| CDC setup/commit failure          | `false`         |
| Pre-existing rows (backfill)      | `NULL`          |

Naming alternatives considered: `is_collateral` (inverted), `caused_rollback`
(less general — non-CDC has no rollback), `is_poisoned` (matches the
"poisoned" mental model but informal). `is_root_cause` is the standard
ops/SRE term and reads cleanly across both code paths.

## Implementation

### 1. Schema migration

Add column to `records_with_errors`:

```sql
ALTER TABLE records_with_errors
  ADD COLUMN is_root_cause boolean;
```

Nullable, no default. Existing rows stay NULL — we don't know retroactively
and a backfill on what may be a large table is not justified. New rows
always populate it.

Locate the migration entrypoint (likely under `internal/sink/postgres` or a
shared schema package) before drafting the migration file.

### 2. Carry the flag through `recordOutcome`

Add a field to [`recordOutcome`](../../sonae/esl/datapipeline/internal/sink/postgres/errors.go) (`internal/sink/postgres/errors.go:20`):

```go
type recordOutcome struct {
    record      *models.Record
    err         error
    isRootCause bool // true when this record's own write produced err;
                    // false when err is a rolledBackErr from a peer
}
```

Set `isRootCause = true` explicitly in `sendAndProcessBatch` when building
outcomes for records whose `br.Exec()` returned non-nil. Override to `false`
in the CDC peer-marking path. Explicit-at-source is easier to reason about
than relying on the zero-value default.

### 3. CDC differentiation in `executeBatchWithCDC`

Replace the SendBatch failure path
(`internal/sink/postgres/write_batch.go:309-313`):

```go
br := tx.SendBatch(ctx, batch)
outcomes, batchErr := s.sendAndProcessBatch(br, records)
if batchErr != nil {
    triggerIdx := firstFailedIndex(outcomes)
    return markPeersAsRolledBack(outcomes, triggerIdx, batchErr), batchErr
}
```

`markPeersAsRolledBack` walks outcomes:

- `i == triggerIdx`: `err = batchErr`, `isRootCause = true`
- `i != triggerIdx`: `err = rolledBackErr(batchErr)`, `isRootCause = false`

The other failure paths in `executeBatchWithCDC` (Begin, DetectChanges,
buildUpsertBatch build error, WriteOutbox, Commit) continue to use
`uniformOutcomes` — but with `isRootCause = false` for every record. No
individual record can be blamed for those failures.

The non-CDC `executeBatch` path is unaffected: its per-record fallback
(`pool.Exec` per record) already gives true outcomes — every failed record
is its own root cause, so set `isRootCause = true` for any record whose
individual exec failed.

### 4. Plumbing to the table

- `buildFailedMeta` ([errors.go:44](../../sonae/esl/datapipeline/internal/sink/postgres/errors.go)) gains an `isRootCause bool` parameter (or reads it from a `recordOutcome`).
- `failedRecordMeta` ([errors.go:33](../../sonae/esl/datapipeline/internal/sink/postgres/errors.go)) gets an `isRootCause bool` field.
- `storeFailedInsert` ([errors.go:93](../../sonae/esl/datapipeline/internal/sink/postgres/errors.go)) adds the column to its INSERT and a placeholder.
- `persistFailedRecord` ([write_batch.go:104](../../sonae/esl/datapipeline/internal/sink/postgres/write_batch.go)) passes `outcome.isRootCause` through.

## Tests

- **Migration test**: column exists, nullable, default null.
- **CDC integration test (new)**: 3-record batch where the middle record
  violates a unique constraint → assert `records_with_errors` has 3 rows:
  middle row `is_root_cause = true` carrying the raw PG error, others
  `is_root_cause = false` carrying `rolledBackErr`.
- **CDC setup-failure test (new)**: simulate a commit failure or
  DetectChanges failure → assert all rows `is_root_cause = false`.
- **Non-CDC test (new or extend)**: each failed row has
  `is_root_cause = true`.
- Update existing test
  [`error_handling_integration_test.go:517`](../../sonae/esl/datapipeline/internal/sink/postgres/error_handling_integration_test.go) — the "uniform per record"
  assertion no longer holds for SendBatch failures.

## Docs

If `records_with_errors` is documented in `docs/` or a config example calls
it out, update it to describe the new column and the operator query pattern
(`WHERE is_root_cause` for actual culprits, `WHERE NOT is_root_cause` for
collateral).

## Out of Scope

- Backfilling `is_root_cause` on historical rows.
- Changing the wrapped-error message format (`rolledBackErr` prefix is kept
  as a secondary signal).
- Schema/structural changes outside `records_with_errors`.

## Notes

- Retry semantics don't change — `batchErr` is what `withRetry` sees, so
  transient errors still retry the whole batch and on success everyone
  persists. The boolean only matters when the batch error is permanent and
  rows land in `records_with_errors`.
- `pg_error_code` stays populated on every row (errors.As walks the wrap
  chain), so peers still surface e.g. `23505` — useful for incident scoping.
- The trigger's outcome err is `batchErr` itself — already classified
  Permanent/Transient via `classifyError` inside `sendAndProcessBatch` — so
  `error_type` on the table stays consistent across trigger and peers.
