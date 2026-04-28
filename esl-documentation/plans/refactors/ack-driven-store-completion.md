# Fix: Ack-driven store completion + improved error observability

**Scope:** datapipeline, database
**Status:** Revised 2026-04-28 (supersedes 2026-04-27 paused version)
**Branch to use:** new branch off `main` (current `feature/schema-qualified-queries` is unrelated)

## Problem

Run 107 on `esl-orchestrator-pp` (2026-04-27) surfaced four distinct but related failures, all stemming from the same architectural gap: **the orchestrator's bookkeeping reflects what was emitted by the connector, not what actually persisted in postgres.**

1. **False success in `store_sync_state`.** Store `sonae_lab_pt.001` recorded as `success` despite ~80 unique-constraint violations on `idx_ap_mac_address`. The watermark advanced and runs 108/109 skipped the failed records.
2. **False positives in `records_with_errors`.** Most rows tagged with `idx_ap_mac_address` are labels — labels don't have a `mac_address` column. They were collateral damage from pgx's batch error cascade.
3. **Silent record loss.** `labels_processed = 427` for that store but the labels table has far fewer rows; only ~80 are in `records_with_errors`. The remaining ~270+ vanished without any trace.
4. **Inflated `*_processed` counters.** Tracked at emission, not persistence. Coincidentally correct for products in run 107; wrong for labels.

## Root cause

| # | Location | Bug |
| --- | --- | --- |
| A | [`metrics.go:111`](internal/connector/metrics.go#L111) + [`sync.go:213-222`](internal/connector/vusion/sync.go#L213-L222) | `MarkStoreCompleted` fires when records are *enqueued* to the sink channel, not when persisted |
| B | [`pgx/v5/batch.go:129-132`](pgx/v5@v5.9.1/batch.go) | `br.Exec()` caches the first error and returns it for every subsequent record in the batch |
| C | [`postgres.go:71-73`](internal/sink/postgres/postgres.go#L71-L73) | `Write()` rejects records after `setAsyncError` without Ack-ing or recording them |
| D | [`sync.go:300-301`](internal/connector/vusion/sync.go#L300-L301) | `IncrementStoreLabels(count)` runs once after streaming, against the count emitted to `outCh` |

All four collapse into one missing primitive: **the sink does not report per-record persistence outcomes back to the connector.** Adding that signal closes all four.

## Solution

Three PRs in dependency order:

1. **PR 1 — Sink correctness foundation.** Make the sink honest about per-record outcomes. No visible change in run-level behavior.
2. **PR 2 — Ack-driven store completion.** Wire those outcomes through to per-store status, counters, and the resolver. The actual bug fix.
3. **PR 3 — Error observability.** `records_with_errors` correlation + `running` lifecycle. Independent of 1 and 2.

PRs 1 and 2 are coupled (PR 2 depends on PR 1). PR 3 is orthogonal and can ship before, with, or after.

---

## PR 1 — Sink correctness foundation

**Goal:** the sink calls `record.Ack(nil)` for every record that genuinely persisted and `record.Ack(err)` for every record that genuinely failed — even when pgx's batch cascade has poisoned the per-record error reporting. No external behavior change yet.

### Changes

#### 1.1 Promote Ack to a Sink interface contract

Update [`internal/sink/sink.go`](internal/sink/sink.go) — add doc comment to the `Sink` interface:

> Sinks MUST invoke `record.Ack` exactly once per record before `Close()` returns. Pass `nil` if the record was successfully persisted, or a non-nil error if it permanently failed. Sinks that drop records (filter, deduplicate) must still Ack with `nil`.

This is a documentation contract; no signature change. Add an `Ack` doc on the field in [`record.go:23`](internal/models/record.go#L23) too.

#### 1.2 Update stdout sink to honor the contract

[`internal/sink/stdout/stdout.go`](internal/sink/stdout/stdout.go) — call `record.Ack(nil)` after each successful write, `record.Ack(err)` on failure.

#### 1.3 Per-record Ack accuracy in `flushBatch`

Today [`postgres.go:215-218`](internal/sink/postgres/postgres.go#L215-L218) Acks all records with the same `err`. Change `writeBatch` to return per-record outcomes:

```go
type recordOutcome struct {
    record *models.Record
    err    error  // nil = persisted, non-nil = permanently failed
}
```

`flushBatch` iterates outcomes and Acks accordingly.

#### 1.4 Outcome semantics differ between CDC and non-CDC paths

The two code paths produce outcomes differently because their persistence guarantees differ.

**Non-CDC path** (`executeBatch`): each `br.Exec() == nil` means the record persisted (its INSERT was implicitly committed). Outcomes are per-record:

- Records `0..firstFailIdx-1` → `{err: nil}` (genuinely persisted before pgx cached the error).
- Record `firstFailIdx` → `{err: realPGError}` (the trigger).
- Records `firstFailIdx+1..end` → re-execute one at a time via `pool.Exec` + `prepareQuery` (still inside `withRetry`). Each gets its own true outcome.

This recovery path is the fix for finding 5 (pgx batch cascade). It runs only after a batch failure, only for records past the first failure.

**CDC path** (`executeBatchWithCDC`): the entire batch runs inside `s.pool.Begin(ctx)`. Persistence is determined by `tx.Commit()` succeeding — `br.Exec() == nil` is necessary but not sufficient. If anything fails (`DetectChanges`, any upsert via `failFast=true`, `WriteOutbox`, or the commit itself), the deferred rollback invalidates everything.

Outcomes are *uniform*:

- Commit succeeds → every record `{err: nil}`.
- Anything fails → every record `{err: rolledBackErr}`, where `rolledBackErr` wraps the root cause (the originating constraint violation, outbox write failure, etc.). Records past `failFast`'s exit point — whose `br.Exec()` was never called — get the same `rolledBackErr` synthetically; we do not try to read their results from the poisoned pipeline.

**The non-CDC fallback retry MUST NOT run in CDC.** Per-record retries outside the original tx would break the upsert/outbox atomicity contract. The CDC path simply produces uniform outcomes from a single source of truth (the commit result).

#### 1.5 Refactor `sendAndProcessBatch` to return ordered outcomes

Today it returns `[]recordFailure` with no positional info. Change it to return a `[]recordOutcome` aligned with `records[]`. `executeBatch` post-processes the non-CDC path (fallback for indices after the first failure). `executeBatchWithCDC` collapses the result to uniform outcomes after the commit/rollback decision is final.

### Code-quality notes

- `recordOutcome` is internal to the sink package — don't leak it.
- Keep the per-record fallback in `executeBatch` (where the batch knowledge lives), not pushed up to `writeBatch`.
- Don't introduce a separate "single-record path" function with its own query plan caching — reuse existing `prepareQuery`.
- The new behavior renames `lastFailures` → `outcomes` to avoid confusion in code review.
- Synthesize `rolledBackErr` with `fmt.Errorf("rolled back due to peer record failure: %w", rootCause)` so the cause is preserved for `errors.Is`/`errors.As`.

### Tests

Integration (testcontainers, follow [`error_handling_integration_test.go`](internal/sink/postgres/error_handling_integration_test.go) patterns):

**Non-CDC:**

- **`TestSink_PartialBatch_PerRecordAck`** — batch of 5, 2 violate constraints. Assert: 3 succeed → `Ack(nil)`, 2 fail → `Ack(<their err>)`. 3 rows in destination, 2 rows in `records_with_errors`.

- **`TestSink_BatchCascade_RecoversSurvivors`** — exact reproduction of run 107 cascade. Order: rec 0 OK, rec 1 violates unique constraint, recs 2-4 valid but in same batch. Assert: 4 rows in destination (recs 0, 2, 3, 4 via fallback), 1 row in `records_with_errors`. 4 records `Ack(nil)`, 1 `Ack(<unique violation>)`.

- **`TestSink_TransientError_RetriesViaWithRetry`** — flaky DB returns transient error then success. Assert `withRetry` recovers the whole batch; all records `Ack(nil)`.

**CDC:**

- **`TestCDC_HappyPath_AllAckedNil`** — regression. All records `Ack(nil)`, all in destination, matching events in `event_outbox`.

- **`TestCDC_BatchFailure_AllRecordsAckedWithRollback`** — one record violates a unique constraint. Assert: all records `Ack(<err wrapping rolledBack>)`, no rows in destination, no events in `event_outbox`. Use `errors.Is` to check the root cause is preserved.

- **`TestCDC_DetectChangesFails_AllRecordsAcked`** — force `DetectChanges` to error. Same all-or-nothing assertion.

- **`TestCDC_OutboxWriteFails_AllRecordsAcked`** — force `WriteOutbox` to fail after successful upserts. Assert: tx rolled back, no destination rows, no outbox rows, all records `Ack(err)`.

**Cross-sink:**

- **`TestSink_StdoutSink_AcksEveryRecord`** — happy path + write error path. Assert Ack called exactly once per record.

Unit:

- **`TestRecordOutcome_OrderingPreserved`** — outcomes returned by `sendAndProcessBatch` align with input order.

### Risks (PR 1)

| Risk | Mitigation |
| --- | --- |
| Phase 1 store records (which already use Ack) get different signals | Phase 1 was already Ack'd with the joined error — now per-record. Add `TestPhase1StoreAck_StillFires` for happy path |
| CDC outbox/destination drift if outcomes lie | Tests assert both `event_outbox` and the destination table together, never one in isolation. This is the canary for any subtle break in CDC outcome semantics |
| Per-record fallback path adds latency on errors | Bounded: only triggers after a batch failure, only for records past the first failure. Measure in tests; document expected overhead in the PR description |
| `withRetry` interaction with single-record fallback | Fallback runs *inside* the `withRetry` invocation. Transient errors retry the whole flow. Test: `TestSink_TransientError_RetriesViaWithRetry` |
| Synthetic `rolledBackErr` lacks PG error code, breaks downstream classification | Wrap the root cause via `%w`; `errors.As(err, &*pgconn.PgError)` still recovers it. `buildFailedMeta` already uses this pattern |

### Rollback

Single revert. No schema changes. Old `flushBatch` behavior (Ack with joined err) is restored. No data loss because PR 2 hasn't shipped yet — `store_sync_state` is still driven by `MarkStoreCompleted`.

---

## PR 2 — Ack-driven store completion

**Goal:** drive `store_sync_state` from sink truth instead of connector enqueue. Closes the original false-success bug. Depends on PR 1.

### Changes

#### 2.1 New per-store metrics

Extend `SyncMetrics` in [`internal/connector/metrics.go`](internal/connector/metrics.go) — all `sync.Map`-backed, mirroring the existing pattern:

- `storePending sync.Map` — `storeID → *atomic.Int64` (records emitted, not yet ack'd)
- `storePersisted sync.Map` — `storeID → *atomic.Int64` per entity type (source of truth for `*_processed`)
- `storePersistenceFailed sync.Map` — `storeID → string` (first error message wins)
- `storePersistenceFailedCount sync.Map` — `storeID → *atomic.Int64`
- `storeStreamingDone sync.Map` — `storeID → bool`

New methods:

```go
RecordEmitted(storeID string)
RecordPersisted(storeID, entityType string, err error)
MarkStoreStreamingDone(storeID string)
GetStorePending() / GetStorePersisted() /
GetStorePersistenceFailures() / GetStoreStreamingDone()
```

Delete `MarkStoreCompleted` and `GetCompletedStores` — grep all callers (test code + run.go) and migrate.

#### 2.2 Wire Acks from connector — pooled callbacks (no per-record allocation)

The naive wiring of Ack creates one closure per record, which for high-volume runs (1M+ records) generates GC pressure (≈200 MB of short-lived closures). To avoid this, pre-build one stable closure per `(storeID, entityType)` tuple via a metrics-side helper:

```go
// metrics.go — returns a stable closure scoped to the tuple.
// The closure captures storeID and entityType once; reused across all records.
func (m *SyncMetrics) AckCallback(storeID, entityType string) func(error) {
    return func(err error) {
        m.RecordPersisted(storeID, entityType, err)
    }
}
```

In `createRecord` ([`vusion.go:192-210`](internal/connector/vusion/vusion.go#L192-L210)), the connector caches the callback per tuple at stream-setup time and assigns the cached function to each record:

```go
// Built once per (store, entity) at the start of streaming:
ack := metrics.AckCallback(storeID, entityType)
// For every record produced in the stream:
record.Ack = ack
```

For ~100 stores × 4 entity types this is 400 closures total instead of millions per run.

`RecordEmitted` is called **after** successful enqueue to `outCh`, not in `createRecord`:

```go
case outCh <- record:
    metrics.RecordEmitted(storeID)
    count++
```

Avoids the leak where `RecordEmitted` fires but the record never reaches the sink due to ctx cancellation.

Apply to products ([`sync.go:258-269`](internal/connector/vusion/sync.go#L258-L269)), labels ([`sync.go:284-295`](internal/connector/vusion/sync.go#L284-L295)), access points ([`vusion.go:299-371`](internal/connector/vusion/vusion.go#L299-L371)).

Replace `MarkStoreCompleted` at [`sync.go:221`](internal/connector/vusion/sync.go#L221) with `MarkStoreStreamingDone`.

#### 2.3 Boundary-rejection Ack in `Write()`

In [`postgres.go:71-73`](internal/sink/postgres/postgres.go#L71-L73), when the sink is in error state and `Write()` returns the stored error:

```go
if err := s.getAsyncError(); err != nil {
    rejectErr := fmt.Errorf("postgres sink is in error state: %w", err)
    if record.Ack != nil {
        record.Ack(rejectErr)
    }
    return rejectErr
}
```

Rejected records don't leak `pending`; the store's persistence error gets recorded.

#### 2.4 Drop-site Acks

Grep `internal/sink/postgres/cdc/`, `internal/pipeline/`, `internal/connector/` for places that consume a `*Record` without forwarding it (CDC no-change path is the known site). Each must call `record.Ack(nil)` explicitly.

Document in code: *"any drop site MUST Ack(nil)"*.

#### 2.5 Shutdown drain

In [`postgres.go:138-148`](internal/sink/postgres/postgres.go#L138-L148), when `s.ctx.Done()` fires, after flushing `s.batch`, also drain `s.recordCh`:

```go
for {
    select {
    case rec := <-s.recordCh:
        if rec.Ack != nil { rec.Ack(s.ctx.Err()) }
    default:
        return
    }
}
```

Records sitting in the buffer when context cancels are properly Ack'd, not leaked.

#### 2.6 New resolver

Replace `failureStatusResolver` in [`run.go:486-501`](cmd/eslorchestrator/run.go#L486-L501):

```go
func failureStatusResolver(
    storeErrors          map[string]string,
    persistenceErrors    map[string]string,
    streamingDone        map[string]bool,
    pending              map[string]int64,
) storeStatusResolver {
    return func(storeID string) (state.SyncStatus, string) {
        if msg, ok := storeErrors[storeID]; ok {
            return state.SyncStatusFailed, msg
        }
        if msg, ok := persistenceErrors[storeID]; ok {
            return state.SyncStatusFailed, "persistence: " + msg
        }
        if !streamingDone[storeID] {
            return state.SyncStatusCancelled, "cancelled: another store failed"
        }
        if n := pending[storeID]; n > 0 {
            return state.SyncStatusFailed, fmt.Sprintf(
                "ack leak: %d records unaccounted for", n)
        }
        return state.SyncStatusSuccess, ""
    }
}
```

Apply the same shape on the success path (`updateSyncStateOnSuccess`) — wrap `successResolver` to still check `pending == 0` and `persistenceErrors`. Even on a "successful" run, a store can have persistence failures.

#### 2.7 Counters from persisted, not emitted

In [`run.go:478`](cmd/eslorchestrator/run.go#L478) and `StoreEntityCounts` ([`metrics.go`](internal/connector/metrics.go)):

```go
ProductsProcessed:     metrics.GetStorePersisted(storeID).Products,
LabelsProcessed:       metrics.GetStorePersisted(storeID).Labels,
AccessPointsProcessed: metrics.GetStorePersisted(storeID).AccessPoints,
```

The Ack callback knows the entity type (it's in `record.Metadata["type"]`). Decision: redefine the existing column semantics in place, document in PR description and changelog. No schema change.

#### 2.8 Invariant log

After `sink.Close()` returns in `run.go`, log a warning if `sum(GetStorePending()) > 0`:

```go
if total := totalPending(metrics.GetStorePending()); total > 0 {
    log.Warn("ack leak detected after sink close",
        zap.Int64("total_pending", total),
        zap.Any("by_store", metrics.GetStorePending()))
}
```

Canary for forgotten Acks. Doesn't fail the run.

### Code-quality notes

- **Don't introduce a `Persistence` struct holding all four maps.** Use them as separate maps with parallel APIs — matches the existing `SyncMetrics` style.
- **Single source of truth for entity type.** The sink reads `record.Metadata["type"]` already. Keep that.
- **Resolver is pure.** No side effects, no I/O, easily table-tested.
- **Ack callbacks must be pooled per `(storeID, entityType)` tuple**, not allocated per record. Per-record closures generate GC pressure on high-volume runs. The `AckCallback` helper in §2.2 is the canonical way.
- **`MarkStoreCompleted` deletion** is a real API removal. Run a full repo grep before merge — only test files and `run.go` should reference it.

### Tests

Integration:

- **`TestStoreSyncStatus_FailedOnSinkConstraintViolation`** — exact reproduction of run 107. Two stores; one has a record that violates a unique constraint at flush time. Assert: violating store → `failed`, other store → `cancelled`, run → `failed`, watermark for failing store does not advance.

- **`TestStoreSyncStatus_PartialBatchFailure_AcrossStores`** — batch contains records from store A and store B; only B's records fail. With PR 1's per-record fallback, A's records persist correctly. Assert: A → `success`, B → `failed`.

- **`TestStoreSyncStatus_AllSuccess`** — happy path regression. All stores → `success`, watermark advances correctly.

- **`TestStoreSyncStatus_CDC_BatchFailure_StoreFailed`** — same as the constraint-violation test but with CDC enabled. Assert store → `failed`, persisted counts = 0, no destination rows, no outbox events.

- **`TestProcessedCounts_ReflectPersistedNotEmitted`** — store with 100 emitted labels, sink fails 30 of them. Assert: `labels_processed = 70`, not 100.

- **`TestBoundaryRejection_AfterAsyncError`** — sink enters error state mid-run. Records emitted afterward are rejected at `Write()`. Assert: rejected records get `Ack(rejectErr)`, store's `persistenceErrors` non-empty, status → `failed`.

- **`TestShutdownDrain_AcksRemainingChannelRecords`** — context canceled with records still in `recordCh`. Assert: every record `Ack(ctx.Err())`, no leaked `pending`.

- **`TestAckLeak_DetectedByResolver`** — synthetic test that emits without Ack-ing. Assert: resolver returns `failed` with "ack leak" message and the invariant log fires.

Unit:

- **`TestMetrics_ConcurrentEmitAck`** — `-race`. 10 goroutines emit, 10 Ack, ensure final pending = 0.
- **`TestMetrics_AckBeforeStreamingDone`** — ack arrives before MarkStreamingDone. Resolver returns correct status.
- **`TestMetrics_AckCallbackPooled`** — verify `AckCallback(s, e)` returns the same `func(error)` reference for repeated calls with the same `(storeID, entityType)` (or document the pooling contract is per-stream, not per-call).
- **`TestResolver_AllBranches`** — table test covering Failed (connector err), Failed (persistence err), Cancelled (no streamingDone), Failed (ack leak), Success.

Benchmarks:

- **`BenchmarkSink_AckOverhead`** — measure per-record Ack cost (atomics + sync.Map lookup) at scale (1M records). Assert no allocations attributable to closure creation in the hot path. Compare against pre-PR-2 baseline; expect ≤ 10% throughput delta.

### Risks (PR 2)

| Risk | Mitigation |
| --- | --- |
| `processRecord` in pipeline transform stage drops the Ack pointer | **Verify before coding:** trace [`pipeline.processRecord`](internal/pipeline/pipeline.go). If it copies the record, ensure `Ack` is propagated. Add `TestPipeline_AckPropagatedThroughTransform` |
| `sink.Close()` doesn't run before resolver on failure path | **Verify before coding:** confirm `defer cleanup()` ([`pipeline.go:149-151`](internal/pipeline/pipeline.go#L149-L151)) completes before `Run` returns. Add invariant: after Run, `sum(pending) == 0` for healthy paths |
| Per-record Ack allocates closures, GC pressure on high-volume runs | Pooled callbacks per `(storeID, entityType)` tuple (§2.2). `BenchmarkSink_AckOverhead` enforces no per-record allocation |
| `*_processed` semantics changed under same column name | Existing dashboards/alerts read this column expecting **emitted** counts; they will see lower numbers after PR 2 (because the fix replaces inflated emitted counts with honest persisted counts). Document in PR description AND a one-line comment on `StoreSyncRun`. Coordinate with anyone consuming this column externally before deploy |
| Streaming-done set during shutdown but pending never reaches 0 | "Ack leak" branch surfaces as `failed` rather than masquerading as `success` |
| Removed `MarkStoreCompleted` callers in tests | Pre-merge grep + bulk update; no production code uses it outside `run.go` |
| Race: ack arrives between `MarkStreamingDone` and snapshot read | Snapshots atomic per-key. Resolver runs *after* `sink.Close()` returns, by which time all Acks have fired. Document the ordering invariant |

### Rollback

Single revert restores `MarkStoreCompleted` semantics. Schema unchanged. In-flight `pending` counters are per-process state, not persisted — zero rollback risk.

---

## PR 3 — `records_with_errors` correlation + run lifecycle

**Goal:** make failed records traceable to their run/store and capture in-flight runs visibly. Independent of PR 1 and PR 2.

### Database

New migration `V1.x.x__records_with_errors_correlation.sql`:

```sql
ALTER TABLE esl.records_with_errors
    ADD COLUMN run_id          BIGINT,
    ADD COLUMN retail_chain_id VARCHAR(255),
    ADD COLUMN store_id        VARCHAR(255),
    ADD COLUMN pipeline_name   VARCHAR(255),
    ADD COLUMN entity_type     VARCHAR(32);

CREATE INDEX idx_records_with_errors_run_id
    ON esl.records_with_errors (run_id);
CREATE INDEX idx_records_with_errors_store
    ON esl.records_with_errors (run_id, retail_chain_id, store_id);
```

All columns nullable — error recording must remain tolerant of state-store latency.

`sync_state.sync_status` accepts `'running'`. Verify whether a CHECK constraint exists in [`V1.0.0.12`](db/migrations/V1.0.0.12__create_sync_state.sql); add migration to extend it if so.

### Code

#### 3.1 Run lifecycle

- `state.SyncStatusRunning` constant.
- New `state.Store.UpdateRun(ctx, runID, status, counts, errMessage)` method.
- In [`run.go`](cmd/eslorchestrator/run.go): insert `running` row at start, update at end (success or failure path).
- On startup, **orphan sweep**: `UPDATE sync_state SET sync_status='failed', error_message='orphaned by orchestrator restart' WHERE sync_status='running' AND pipeline_name=$1`. Documented in operations notes that any `running` row at startup is presumed dead.

#### 3.2 `run_id` plumbing into the sink

**Decision: setter, not constructor or context.** Add `sink.SetRunID(int64)` called once per run. Rationale:
- Clean: no `ctx.Value` access.
- Mockable: easy to test in isolation.
- No per-run sink rebuild.
- Explicit dependency, visible at the call site.

#### 3.3 Failed-record metadata

In [`errors.go`](internal/sink/postgres/errors.go), `failedRecordMeta` gains:

```go
storeID       string  // from record.RawData["store_id"]
retailChainID string  // from record.RawData["retail_chain_id"]
pipelineName  string  // from sink config
entityType    string  // from record.Metadata["type"]
```

(Field names are post-normalizer: `store_id` and `retail_chain_id`, *not* `storeId` / `retailChainId`.)

`storeFailedInsert` writes the new columns. `runID` comes from the sink struct.

### Code-quality notes

- The setter pattern for `runID` is a deliberate trade. Document why in a comment on `SetRunID`.
- No FK from `records_with_errors.run_id` to `sync_state.id` — error recording must survive sync_state failures.
- No `entity_type` validation at insert — let it be free-form (the existing `table_name` already serves as constrained enum).

### Tests

Integration:

- **`TestRecordsWithErrors_HasRunIdAndStoreId`** — after a failed run, query `records_with_errors` directly by `run_id` and assert rows have correct `store_id` / `retail_chain_id` / `pipeline_name` / `entity_type`.
- **`TestSyncState_InsertedAtRunStart`** — `running` row exists during pipeline execution.
- **`TestSyncState_UpdatedAtRunEnd_Success`** + **`TestSyncState_UpdatedAtRunEnd_Failure`** — status transitions.
- **`TestStaleRunning_SweptOnStartup`** — pre-insert `running` row, start orchestrator, assert it transitions to `failed`.
- **`TestRecordsWithErrors_BackwardCompat`** — pre-PR-3 rows (NULL `run_id`) still queryable.

### Risks (PR 3)

| Risk | Mitigation |
| --- | --- |
| Lifecycle change exposes `running` rows to dashboards | Coordinate with dashboard owner. Document as a feature, not a bug |
| Orphan sweep misclassifies a still-running orchestrator on a different host | Sweep is per-pipeline-name. Pipeline-name uniqueness is documented as an invariant. Startup log: "swept N orphaned running rows" |
| Schema migration locks `records_with_errors` during ALTER | ADD COLUMN is metadata-only in PG (fast). Verify table size in pp before running. Maintenance window if needed |
| Pre-PR-3 rows have NULL `run_id`, alerts/dashboards break | Columns nullable; pre-existing rows unaffected. Dashboards filtering on `run_id` should handle NULL |

### Rollback

Schema migration is additive. Rolling back code without rolling back schema: writes simply don't populate new columns (NULL). Code rollback safe.

---

## Cross-cutting

### Pre-coding verifications (must happen before PR 1 starts)

1. **Pipeline transform preserves Ack pointer.** Trace [`pipeline.processRecord`](internal/pipeline/pipeline.go). If it copies the record, ensure `Ack` is propagated. Add a regression test.
2. **`sink.Close()` runs synchronously before resolver on the failure path.** [`pipeline.go:106`](internal/pipeline/pipeline.go#L106) calls Close on success; on failure, `defer cleanup()` ([`pipeline.go:149-151`](internal/pipeline/pipeline.go#L149-L151)) handles it. Confirm `cleanup` runs to completion before `pipeline.Run()` returns.
3. **Grep all record-drop sites:** `internal/sink/postgres/cdc/`, `internal/pipeline/`, `internal/connector/`. Document the list.
4. **Grep all `MarkStoreCompleted` / `GetCompletedStores` callers.** Confirm only `run.go` + tests.

### Drop-site Ack policy (decision locked)

**Option 1 chosen: explicit `record.Ack(nil)` at every drop site.**

Trade vs counter-only model (every emit `++`, every persist-or-drop `--`):
- ✅ Easier to debug: each Ack call is a stack-traceable event.
- ✅ Each Ack carries an outcome (nil/err), useful for richer reporting.
- ❌ Forget-prone: a new drop site without `Ack(nil)` causes a leak.

Mitigation: resolver's "ack leak" branch surfaces this loudly. `sum(pending) == 0` invariant log on Close. Interface contract documentation in PR 1.

### Operational step after deploy

PR 2 alone does not backfill run 107's lost data. Once shipped, manually recover `sonae_lab_pt.001`'s missing labels:

```sql
-- Either widen lookback for one run:
UPDATE esl.store_sync_state
   SET synced_at = synced_at - INTERVAL '6 hours'
 WHERE pipeline_name='esl-orchestrator-pp'
   AND retail_chain_id='sonae_lab_pt' AND store_id='sonae_lab_pt.001'
   AND id=(SELECT MAX(id) FROM esl.store_sync_state
            WHERE retail_chain_id='sonae_lab_pt' AND store_id='sonae_lab_pt.001');

-- Or trigger one targeted run with a wider lookback_window config.
```

Document this in the PR 2 description.

### Verification

```bash
go build ./...
go test ./...                          # unit + integration
go test ./internal/connector/... -v
go test ./internal/sink/postgres/... -v
go test -race ./internal/connector/...
go test -bench=BenchmarkSink_AckOverhead ./internal/sink/postgres/...
```

E2E (godog) is **not** run after code changes — manual via `make test-e2e` only.

## Risks (cross-PR)

| Risk | Mitigation |
| --- | --- |
| Sink panic mid-flush leaks Acks | Out of scope. Tracked separately. Add a comment in the Close path noting the assumption |
| Future sinks don't honor Ack contract | Interface contract documented in PR 1. Future hook: CI conformance test. Out of scope here |
| Customer dashboards depend on pre-fix `*_processed` semantics | Document in PR 2's description and changelog. The new value is *more* honest; consumer alerting should be retuned if it depends on inflated counts |
| Test flakiness from timing-sensitive batch composition | Tests use small `BatchSize` (e.g. 5) + explicit `Flush()` calls. Don't rely on `BatchTimeout` |

## Out of scope

- **Sink worker panic recovery.** Existing issue, not introduced here.
- **Run 107 backfill.** Manual operational step, not code.
- **Constraint redesign on `idx_ap_mac_address`.** Customer-side decision; the constraint is intentional. Orchestrator's job is to be honest about violations rather than swallow them.
- **Concurrent orchestrator instances.** Pipeline-name uniqueness assumed.

## Decisions locked

- **PR order:** 1 → 2 → 3. PRs 1 and 2 coupled; PR 3 orthogonal.
- **Sink Ack contract:** documented at the interface level, enforced by tests, monitored by an invariant log.
- **CDC outcome semantics:** uniform per-batch (all-success or all-failure tied to `tx.Commit`). No per-record fallback in CDC.
- **Ack callback pooling:** per `(storeID, entityType)` tuple, not per record. Enforced by benchmark.
- **`run_id` plumbing:** setter on the sink (`SetRunID`).
- **Drop-site Acks:** explicit `Ack(nil)` at every site.
- **Counter semantics:** `*_processed` columns redefined in place to mean persisted. No schema split.
- **Lifecycle:** insert `running` at start, update at end. Orphan sweep on startup.
- **Run 107 recovery:** manual operational step, documented in PR 2.

---

## Pause notes (historical, 2026-04-27)

Original plan reviewed by user; no code changes started. Resume by:
1. Creating new branch off `main`
2. Running pre-coding verifications listed under PR 1
3. Greping for all `MarkStoreCompleted` / `GetCompletedStores` callers
4. Greping for record-drop sites in `internal/sink/postgres/cdc/`, `internal/pipeline/`, `internal/connector/`

This plan was revised on 2026-04-28 after a deeper review surfaced four findings that the original draft underweighted:
- pgx batch error cascade (records_with_errors false positives)
- Silent record loss at the sink boundary
- `*_processed` counters tracking emission, not persistence
- CDC path needing explicit uniform-outcome semantics in the new model

The revision restructured PR 1 (now "sink correctness foundation"), expanded PR 1's scope to cover the cascade and CDC outcome model, added boundary-rejection Ack and counter redefinition to PR 2, locked in pooled Ack callbacks for performance, and kept PR 3 (the lifecycle/correlation work) unchanged.
