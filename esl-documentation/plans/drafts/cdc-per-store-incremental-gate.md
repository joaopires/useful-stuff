# CDC — Per-Store Incremental-Only Gate

## Problem

Today the sink's CDC mechanism is gated by a single global flag
(`sink.postgres.cdc.enabled`). When the flag is on, every record that flows
through the sink is compared against the live row state and produces
CREATED / UPDATED / DELETED outbox events. The same flag also controls
whether the VLink connector includes soft-deleted rows in its paginated
walk.

This is wrong for stores that have no prior sync history. Three scenarios
cover all of them:

1. **Store has prior successful sync** — incremental run; CDC should run.
2. **Brand-new store** — no prior row in `store_sync_state`; the whole
   catalogue (tens of thousands of products + labels) is new to the sink.
   CDC would emit a CREATED event for every record. We do not want that
   flood.
3. **Store whose state was wiped to force a full sync** — operationally
   indistinguishable from case 2; same flood applies.

The decision is **per store**, not per run. The current global flag
cannot express it.

References:

- Sink CDC dispatch: [`executeBatchWithCDC`](../../sonae/esl/datapipeline/internal/sink/postgres/write_batch.go) (`internal/sink/postgres/write_batch.go:277`, called from `executeBatch:197`)
- VLink `deleted=true` gate: [`doRequest`](../../sonae/esl/datapipeline/internal/connector/vusion/vlink/client.go) (`internal/connector/vusion/vlink/client.go:288`; field read at `:303`)
- Per-store state load: [`doSync`](../../sonae/esl/datapipeline/internal/connector/vusion/sync.go) (`internal/connector/vusion/sync.go:169`)
- State interface: [`Store`](../../sonae/esl/datapipeline/internal/state/state.go) (`internal/state/state.go:55`)

## Goal

CDC events are emitted only for stores that already have a successful
`store_sync_state` row. New stores, and stores whose history was wiped,
sync their full catalogue into the sink DB without producing any CDC
outbox events.

The global `sink.postgres.cdc.enabled` flag remains the master switch
(off ⇒ no CDC anywhere, regardless of per-store state). When on, the
per-store gate is applied on top.

## Design — Option B (run-scoped store registry)

The connector already computes the eligibility predicate at
`sync.go:169` via `GetLatestSuccessfulStoreRuns`: stores absent from the
returned map are full-sync, stores present are incremental. We propagate
this set to two consumers:

1. **Sink** — at the start of each run, after phase 1 finishes and state
   has been loaded, the sink receives the set of CDC-eligible store keys.
   CDC's `DetectChanges` filters records whose store is **not** in the
   set before the existing-row SELECT and outbox INSERT. Filtered
   records still upsert normally — they just produce no events.
2. **VLink client** — `includeDeleted` becomes a per-call parameter
   instead of a client-level flag. The per-store loop in
   `processStoreEntities` passes `cdcEnabled && hasPriorSuccess` per
   store.

Why the run-scoped registry over a per-record `SkipCDC` flag:

- Eligibility is genuinely per-store, not per-record. Stamping it on every
  `*models.Record` is layering noise on a generic data type for a
  sink-specific decision.
- The set is built once and consulted O(1) per record. No batch
  partition step in the hottest path.
- Set is naturally extensible later if we need richer per-store CDC
  config (per-store entity-type opt-out, etc.) without churning the
  record model.

### Wiring shape

We avoid coupling connector and sink directly. The orchestrator owns the
glue: it provides the connector with a callback that, when invoked,
configures the sink's filter. Symmetric to the existing `SetRunID`
pattern.

```text
phase 1 (stream stores) ──┐
                          ├──► GetLatestSuccessfulStoreRuns(storeKeys)
                          │            │
                          │            ▼
                          │   (connector projects map[StoreKey]*StoreSyncRun
                          │    down to the keys-only set used for gating)
                          │            │
                          │            ▼
                          │   onStoreStatesLoaded(eligibleKeys)  ──► snk.SetCDCEligibleStores(eligibleKeys)
                          │                                              │
                          │                                              ▼
                          │                                    cdc.eligibleStores set
                          ▼
phase 2 (per-store fetch) ──► VLink calls with per-store includeDeleted flag
                          ──► sink.Write(record) ──► CDC consults eligibleStores
```

## Implementation

### 1. State / models

No schema changes. The existing `store_sync_state` table and
`GetLatestSuccessfulStoreRuns` already give us the predicate.

### 2. Sink — add per-run CDC-eligible store registry

[`internal/sink/postgres/postgres.go`](../../sonae/esl/datapipeline/internal/sink/postgres/postgres.go)

Add a field on `PostgresSink`:

```go
// cdcEligibleStores is the set of (RetailChainID, StoreID) pairs whose
// non-Store records should produce CDC outbox events when CDC is
// enabled. Records whose store is not in the set still upsert but
// skip change-detection. Store-entity records are exempt (always
// eligible) — see filterEligible. Set once per run via
// SetCDCEligibleStores. A nil pointer means the set has not been
// installed yet — every record is treated as eligible, matching the
// pre-rollout default. This is the safe no-op for step 1 of the
// rollout (where the partition lands without a caller wiring the
// callback) and for test fixtures that don't exercise per-store
// gating. Once step 3 wires the connector callback, every production
// run installs a (possibly empty) set before the first Write.
cdcEligibleStores atomic.Pointer[map[state.StoreKey]struct{}]
```

Add a setter on the `Sink` interface ([`internal/sink/sink.go`](../../sonae/esl/datapipeline/internal/sink/sink.go)):

```go
// SetCDCEligibleStores installs the set of stores eligible for CDC
// event emission for the current run. Records belonging to stores
// outside this set still persist normally but produce no outbox
// events for non-Store entity types. Store-entity records are exempt
// (always eligible) so brand-new stores still get a CREATED event
// downstream. Must be called before any Write that may trigger CDC;
// calling after Write is permitted but races on the goroutine
// boundary.
SetCDCEligibleStores(stores map[state.StoreKey]struct{})
```

Goes on the interface (not just the concrete type) so test fixtures
can fake the sink without depending on `*PostgresSink`. Non-postgres
sinks (none today) implement it as a no-op.

### 3. CDC — partition records by eligibility

[`internal/sink/postgres/cdc.go`](../../sonae/esl/datapipeline/internal/sink/postgres/cdc.go)

`DetectChanges` is the right cut point. After `groupByEntityType`, before
the existing-row SELECT, filter each group to records whose
`(retail_chain_id, store_id)` is in `eligibleStores`. Records dropped
from CDC processing remain in the upsert batch (the sink path that calls
`buildUpsertBatch` is independent of CDC).

Pseudocode:

```go
func (c *CDC) DetectChanges(
    ctx context.Context,
    tx pgx.Tx,
    records []*models.Record,
    tables map[string]TableConfig,
    batchTimestamp time.Time,
    eligible map[state.StoreKey]struct{}, // new
) ([]event.ChangeEvent, error) {
    eligibleRecords := filterEligible(records, eligible)
    if len(eligibleRecords) == 0 {
        return nil, nil
    }
    groups := groupByEntityType(eligibleRecords, tables, c.schema)
    // …existing logic unchanged
}
```

Helper `filterEligible` extracts the store key from each record's
conflict-key fields and looks it up in `eligible`. **Store-entity
records are exempt** — they always pass through CDC regardless of the
set, because we cannot distinguish a truly new store from one that
exists in VLink but has no row in the sink yet, and downstream
consumers need a `Store CREATED` event in either case. The exemption
is a single entity-type check at the top of `filterEligible`:

```go
func filterEligible(
    records []*models.Record,
    eligible map[state.StoreKey]struct{},
) []*models.Record {
    // Nil eligible ⇒ caller has not installed the set; treat every
    // record as eligible (pre-rollout default). This makes step 1 of
    // the rollout a no-op.
    if eligible == nil {
        return records
    }
    out := make([]*models.Record, 0, len(records))
    for _, record := range records {
        entityType, _ := record.Metadata["type"].(string)
        if entityType == entity.Store {
            out = append(out, record)
            continue
        }
        key := storeKeyOf(record) // (retail_chain_id, store_id) from conflict keys
        if _, ok := eligible[key]; ok {
            out = append(out, record)
        }
    }
    return out
}
```

Note: entity types in this codebase are bare strings (see
`entity.Store = "store"`) and are carried on records via
`Metadata["type"]`, not a typed struct field. The pseudocode reflects
that.

Volume note: a brand-new store under this gate emits exactly one
`Store CREATED` event and zero Product/Label/AccessPoint events.
That's the desired outcome — one event per onboarded store, no flood.

`executeBatchWithCDC` ([`write_batch.go:277`](../../sonae/esl/datapipeline/internal/sink/postgres/write_batch.go)) passes the
loaded eligibility set into `DetectChanges`. The set is read once per
batch via `s.cdcEligibleStores.Load()` and passed in. A nil pointer
(no caller has installed the set yet) means "all records eligible" —
the pre-rollout default — so `filterEligible` is a pass-through and
CDC behaves exactly as it does today. Once step 3 of the rollout
wires the connector callback, every production run installs a
(possibly empty) concrete set before the first Write reaches the
sink, so the nil branch is in practice only used during rollout step 1
and in tests.

### 4. Connector — emit eligibility callback

[`internal/connector/vusion/sync.go`](../../sonae/esl/datapipeline/internal/connector/vusion/sync.go)

Add an optional callback on the connector struct:

```go
type vusionConnector struct {
    // …existing
    onStoreStatesLoaded func(eligible map[state.StoreKey]struct{})
}
```

The callback receives **just the keys** of stores with prior successful
sync (not the full `*StoreSyncRun` values). The sink only needs the
predicate; emitting the keys-only shape directly from the connector
keeps the orchestrator free of any conversion step and avoids leaking
`StoreSyncRun` into a sink-facing contract.

In `doSync`, immediately after the successful
`GetLatestSuccessfulStoreRuns` call (line 169) and before phase 2 starts,
build a `map[state.StoreKey]struct{}` projection from `storeStates` and
invoke the callback with it (if non-nil). The callback runs
synchronously on the sync goroutine; sink-side work behind it must be
fast (it is — an `atomic.Pointer.Store` of a single map).

Connector construction: add an `OnStoreStatesLoaded
func(map[state.StoreKey]struct{})` field on `ConnectorOptions` (see
`vusion.go:55-91`). `NewVusionConnector` copies it from `opts` into the
private `onStoreStatesLoaded` field on `vusionConnector`. No builder
pattern is involved — the connector uses an options struct today and
this slots in alongside the existing fields.

#### Race window — why the publish is safe

The callback fires synchronously on the sync goroutine **before** phase
2's worker pool starts (`pool.Start()` at `sync.go:230`). The sink-side
setter publishes the new set via `atomic.Pointer.Store`, and every
phase 2 record path that calls `executeBatchWithCDC` reads it back via
`.Load()`. Go's `atomic.Pointer` guarantees a happens-before
relationship between the publishing `Store` and a subsequent `Load`,
so phase 2 workers always observe the populated set.

The only records that flow before the callback runs are phase 1's
`Store` entity records (lines 117-125 of `sync.go`). Those are exempt
from the filter unconditionally (`Store` entity always CDC-eligible),
so they would be passed through even if the sink were operating on
the nil/pre-rollout default. The race window is therefore benign.

If `GetLatestSuccessfulStoreRuns` returns an error, `doSync` aborts at
`sync.go:178` before phase 2 starts and the callback is never
invoked. No record reaches the sink in that path, so the sink
retaining its pre-callback (nil) state never matters operationally.

### 5. VLink — per-call `includeDeleted`

[`internal/connector/vusion/vlink/client.go`](../../sonae/esl/datapipeline/internal/connector/vusion/vlink/client.go)

Drop the `includeDeleted bool` field from `vlinkClient` (currently at
`client.go:35`). Plumb the value through the call chain instead:

- The four public list methods gain an `includeDeleted bool` parameter
  in their signatures:
  - `StreamAllProducts`
  - `StreamProductsModifiedSince`
  - `StreamAllLabels`
  - `StreamLabelsModifiedSince`

  Access-point records are extracted from the store object on the
  connector side (see `extractAccessPointRecords` in `sync.go`), so
  VLink has no access-point endpoint to plumb.
- The generic `streamAllPages` helper does not need to change — it
  already takes a `fetchPage` closure. The closures inside
  `StreamAllProducts` / `StreamProductsModifiedSince` /
  `StreamAllLabels` / `StreamLabelsModifiedSince` forward the new
  argument into `getAllProducts` / `getAllLabels`.
- `getAllProducts` and `getAllLabels` accept `includeDeleted` and
  thread it into `doRequest`.
- `doRequest` (`client.go:288`) reads `includeDeleted` from its
  argument and sets the `deleted=true` query param accordingly
  (currently this branch reads `vlc.includeDeleted` at `client.go:303`).
- `NewClient` loses the `includeDeleted bool` parameter (currently at
  `client.go:50`).

The `VLinkClient` interface in `vusion.go:24-30` changes to match.
Existing mocks and call sites must be updated (see Rollout step 2).

The connector's `processStoreEntities`
([`sync.go:251`](../../sonae/esl/datapipeline/internal/connector/vusion/sync.go)) computes
`cdcEnabled && params.syncMode == SyncModeIncremental` and forwards it
to each VLink call. Note: `params.syncMode` is itself derived from
`storeStates[key]` exists/absent at `sync.go:197-210`, so the
per-call `includeDeleted` and the sink-side eligibility set are
necessarily consistent — both come from the same `storeStates` map at
the same point in time.

This means full-sync stores never request `deleted=true`, even when CDC
is globally enabled. Consistent with the sink-side gate: no DELETED
records in, no DELETED events out.

### 6. Orchestrator wiring

[`cmd/eslorchestrator/run.go`](../../sonae/esl/datapipeline/cmd/eslorchestrator/run.go)

Today `createConnector` runs **before** `createSink` in `createPipeline`
(`run.go:264-273`). That order needs to flip so the connector's
`OnStoreStatesLoaded` callback can reference the sink at construction
time.

Reorder `createPipeline` to:

1. Build the sink first via `createSink`.
2. Build the connector via `createConnector(..., snk)`, passing the
   sink in.
3. Continue with transformer + pipeline builder as today.

Inside the new `createConnector` signature:

- Take the sink as a parameter.
- Build the connector with
  `ConnectorOptions{OnStoreStatesLoaded: snk.SetCDCEligibleStores, ...}`.
  Because the callback type is `func(map[state.StoreKey]struct{})` —
  exactly the signature of `SetCDCEligibleStores` on the `Sink`
  interface — no adapter or conversion is needed. The method value
  itself is the callback.

VLink client construction loses the `cdcEnabled` argument (now
per-call). The connector itself keeps `cdcEnabled` to make the
per-call decision in `processStoreEntities`.

The existing comment block on `cdcEnabled` in `createPipeline` ("must
include deleted rows in its paginated walk for the sink to ever see
DELETED records") becomes outdated. Replace it with a one-line note
that the connector now decides per store and per call.

## Testing

### Unit tests

- `cdc_test.go`: `DetectChanges` with mixed records — half eligible,
  half not. Assert outbox events only for the eligible half; assert
  group-fetch SELECT only queried for the eligible store keys.
- `cdc_test.go`: nil / empty eligibility set ⇒ zero events even with
  records present.
- `vlink/client_test.go`: per-call `includeDeleted=true` adds the
  param; `false` omits it. Existing client-level flag tests removed
  or rewritten.
- `sync_test.go` (connector): mock state store returning a partial map;
  assert `OnStoreStatesLoaded` invoked with the keys-only projection
  (`map[StoreKey]struct{}`) — i.e. exactly the keys of the partial map
  returned by the state store. Assert per-store VLink calls receive
  `includeDeleted=true` only for stores with prior state.

### Integration tests (testcontainers)

- `cdc_integration_test.go`: seed `store_sync_state` with one store,
  leave another absent; run a write batch carrying records for both
  stores; assert `event_outbox` rows only for the seeded store; assert
  both stores' rows present in the entity tables.
- Fresh-pipeline integration: empty `store_sync_state`, CDC enabled;
  assert zero outbox rows after a full sync.
- Incremental-after-full integration: run 1 with empty state (zero
  events), insert success row, run 2 with new/changed rows; assert
  proper CREATED / UPDATED events on run 2.

### E2E (manual, not part of CI)

Add a godog scenario covering the bootstrap-then-incremental flow if
`godog-e2e/` already exercises CDC. Skip if not — the integration
coverage is sufficient.

## Repository documentation updates

Files to update inside the datapipeline repo (`docs/`):

- [`docs/postgres-sink.md`](../../sonae/esl/datapipeline/docs/postgres-sink.md) — CDC section: explain the per-store
  gate, its trigger condition (`store_sync_state` presence), and the
  interaction with the global `cdc.enabled` flag.
- [`docs/state-management.md`](../../sonae/esl/datapipeline/docs/state-management.md) — add a paragraph clarifying that
  deleting `store_sync_state` rows is the operational lever to force a
  full re-sync without CDC events.
- Example config files (`config-*.yaml`, `examples/*.yaml`) — no field
  changes (still one global `cdc.enabled`), but add a comment near the
  flag pointing at the new per-store behaviour.
- `CLAUDE.md` — no change (no new patterns or commands).

## Phase 2 documentation updates

Files to update under `esl-documentation/phase-2/`:

- [`04-datapipeline.md`](../phase-2/04-datapipeline.md) — the CDC section currently says "The flag also gates
  the VLink connector's `deleted=true` query param: when CDC is on, list
  calls include soft-deleted rows…". This becomes per-store: list calls
  include soft-deleted rows **only for stores with prior successful
  sync**, gated by both the global flag and the per-store predicate.
  Update the prose, the dispatch description (`s.cdc != nil` is no
  longer the full picture), and any diagrams that show the boolean
  gate.
- [`02-architecture.md`](../phase-2/02-architecture.md) — touch only if it depicts the CDC gate as a single
  toggle. Re-run `make` to regenerate diagrams if any `.mmd` changes.
- [`07-operations.md`](../phase-2/07-operations.md) — add two
  operations notes:
  1. **Onboarding a new store**: just configure it; the pipeline
     bootstraps it on the next run, emits exactly one `Store CREATED`
     event, and suppresses the per-entity event flood. No special
     procedure required.
  2. **Forcing a full re-sync for an existing store**: deleting only
     `store_sync_state` is insufficient. The runbook must spell out a
     SQL snippet that deletes from **four** tables for a given
     `(retail_chain_id, store_id)` in one transaction:
     - `store_sync_state` — to force the per-store gate to treat the
       store as "no prior history" on the next run.
     - `stores` — **required**, not optional. Without this delete the
       sink's `stores` row still exists, the next run's Store record
       diffs as UNCHANGED, no `Store CREATED` event fires, and
       downstream consumers never learn that the catalogue is being
       re-bootstrapped. This contradicts the "Store entity always
       CDC-eligible" decision the per-store gate is built around.
     - `products`, `labels`, `access_points` — to prevent stale rows.
       A full sync re-upserts the active set but never deletes, and
       VLink soft-deletes after the wipe never reach the sink (no
       `deleted=true` fetch in full-sync mode).

     All four deletes must run in a single transaction so the next
     run's start sees a consistent "no rows for this store" view
     across all tables.
- Phase 2 PDF — regenerate via `make` after the markdown updates.

## Decisions

These were open questions during design; closed before this plan was
finalised.

1. **`SetCDCEligibleStores` lives on the `Sink` interface**, not
   the concrete `*PostgresSink`. Better testability — fixtures can
   fake the sink without depending on the postgres type. Non-postgres
   sinks implement it as a no-op.
2. **`Store` entity is always CDC-eligible.** The gate exempts the
   `Store` entity type unconditionally, so brand-new stores still
   emit a `Store CREATED` event downstream. Rationale: the sink can't
   distinguish "new in VLink" from "existing in VLink but never
   synced here," and downstream consumers need to learn about the
   store either way. Exactly one event per onboarded store, no flood.
3. **Wiped-state DB residue is documented, not automated.** Deleting
   only `store_sync_state` rows leaves stale entity rows behind in
   `products` / `labels` / `access_points` (the full sync re-upserts
   the active set but never deletes — no `deleted=true` fetch, no
   DELETED events). Operators forcing a full sync must wipe the
   entity rows too. The `07-operations.md` runbook will spell this
   out (see Phase 2 documentation updates below).

## Deferred / follow-up

- **Explicit operator command.** A `--reset-store <chain>:<store>`
  CLI flag wrapping the state-wipe and entity-row delete in one
  atomic operation would harden the case-3 procedure. Out of scope
  for this plan; track separately.

## Rollout

1. Land sink + CDC partition (steps 2–3) — backwards compatible: with
   no filter installed, behaviour is "all records eligible," matching
   today. This PR adds `SetCDCEligibleStores` to the `Sink` interface,
   so it must include a `make mock-gen` regeneration of
   [`mocks/Sink_mock.go`](../../sonae/esl/datapipeline/mocks/Sink_mock.go).
   The generated mock will gain the new method automatically; only
   test sites that explicitly assert on `SetCDCEligibleStores` (none
   today) would need additional setup.
2. Land VLink per-call refactor (step 5) — pure refactor; behaviour
   unchanged when caller passes the same flag everywhere. This PR
   changes the `VLinkClient` interface signatures and requires
   regenerating [`mocks/v_link_client_mock.go`](../../sonae/esl/datapipeline/mocks/v_link_client_mock.go)
   via `make mock-gen`. Existing call sites in
   `internal/connector/vusion/sync_test.go` and `vusion_test.go` —
   which stub `StreamAllProducts`, `StreamProductsModifiedSince`,
   `StreamAllLabels`, and `StreamLabelsModifiedSince` — need their
   argument lists updated. Concrete callers in non-test code (only
   `vusion.go`'s streamProductRecords / streamLabelRecords paths)
   also need the new argument.
3. Land connector callback + orchestrator wiring (steps 4 + 6) —
   activates the new behaviour. Single PR. Includes the `createPipeline`
   reorder (sink-before-connector) called out in Section 6.
4. Documentation PR (repo + phase 2) once the code lands.

No feature flag — the change is correctness-focused and the previous
behaviour was undesired in production.
