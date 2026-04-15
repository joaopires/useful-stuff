# Fix: Add retail_chain_id to store_sync_state

**Scope:** database, datapipeline
**Depends on:** refactor-extract-shared-constants (6c — store ID stripping)
**Status:** Done (2026-04-10, folded into migration V1.0.0.15 + datapipeline commit `910b0aa`)

## Problem

After stripping the composite `store_id` prefix (step 6c), the `store_sync_state` table identifies stores by `store_id` alone. If two retail chains have the same store number (e.g., `continente_pt.000010` and `sonae_mc.000010` → both `000010`), they collide:

- **State lookup:** `GetLatestSuccessfulStoreRuns` queries by `store_id` — returns wrong state for the wrong chain
- **State insert:** `InsertStoreRun` writes with only `store_id` — retention trigger groups stores from different chains together
- **Metrics map:** `SyncMetrics.storeMetrics` is keyed by `storeID` string — counts from different chains merge

Before the strip, the composite `store_id` was unique across chains by construction (`continente_pt.000010` ≠ `sonae_mc.000010`). After the strip, `retail_chain_id` must be added as an explicit discriminator.

## Solution

Add `retail_chain_id` to `store_sync_state` and thread it through the state interface, connector metrics, and all callers.

## Database changes

### Migration: modify V1.0.0.15

Since V1.0.0.14–18 are not yet deployed, V1.0.0.15 (`strip_composite_store_id`) is modified to also:

1. Add `retail_chain_id VARCHAR(255) NOT NULL DEFAULT ''` to `store_sync_state`
2. Populate `retail_chain_id` from the composite `store_id` prefix (SPLIT_PART on `'.'`, take first part) — **before** stripping the `store_id` value
3. Strip `store_id` as before
4. Drop and recreate the lookup index to include `retail_chain_id`
5. Replace the retention trigger function to group by `(pipeline_name, retail_chain_id, store_id)` instead of `(pipeline_name, store_id)`

**Order within the migration:**
```sql
-- 1. Add column (with default so existing rows get a value)
ALTER TABLE esl.store_sync_state
  ADD COLUMN retail_chain_id VARCHAR(255) NOT NULL DEFAULT '';

-- 2. Populate from composite store_id (before stripping)
UPDATE esl.store_sync_state
   SET retail_chain_id = SPLIT_PART(store_id, '.', 1)
 WHERE store_id LIKE '%.%';

-- 3. Strip store_id (all tables, as before)
UPDATE esl.stores SET store_id = SPLIT_PART(store_id, '.', 2) WHERE store_id LIKE '%.%';
-- ... (products, labels, access_points, store_sync_state)

-- 4. Recreate index
DROP INDEX esl.idx_store_sync_state_lookup;
CREATE INDEX idx_store_sync_state_lookup
    ON esl.store_sync_state (pipeline_name, retail_chain_id, store_id, sync_status, synced_at DESC);

-- 5. Replace retention trigger function
CREATE OR REPLACE FUNCTION esl.trg_store_sync_state_retention()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM esl.store_sync_state
    WHERE pipeline_name = NEW.pipeline_name
      AND retail_chain_id = NEW.retail_chain_id
      AND store_id = NEW.store_id
      AND id NOT IN (
          SELECT id
          FROM esl.store_sync_state
          WHERE pipeline_name = NEW.pipeline_name
            AND retail_chain_id = NEW.retail_chain_id
            AND store_id = NEW.store_id
          ORDER BY synced_at DESC
          LIMIT 20
      );
    RETURN NULL;
END;
$$;
```

## Datapipeline changes

### State struct: add RetailChainID

**File: `internal/state/state.go`**

Add `RetailChainID string` to `StoreSyncRun`:

```go
type StoreSyncRun struct {
    ID                    int64
    RunID                 int64
    PipelineName          string
    RetailChainID         string  // NEW
    StoreID               string
    SyncStatus            SyncStatus
    ProductsProcessed     int64
    LabelsProcessed       int64
    AccessPointsProcessed int64
    SyncedAt              time.Time
    ErrorMessage          string
}
```

### State interface: change lookup signature

**File: `internal/state/state.go`**

The current signature uses `storeIDs []string` and returns a map keyed by `store_id`. After the fix, lookups need both `retail_chain_id` and `store_id`.

Define a key type for the lookup:

```go
// StoreKey identifies a store by its retail chain and store ID.
type StoreKey struct {
    RetailChainID string
    StoreID       string
}
```

Change the interface:

```go
GetLatestSuccessfulStoreRuns(
    ctx context.Context,
    pipelineName string,
    storeKeys []StoreKey,
) (map[StoreKey]*StoreSyncRun, error)
```

### State SQL: GetLatestSuccessfulStoreRuns

**File: `internal/state/postgres/postgres_state.go`**

The current query:
```sql
SELECT DISTINCT ON (store_id) ...
FROM store_sync_state
WHERE pipeline_name = $1 AND store_id = ANY($2) AND sync_status = 'success'
ORDER BY store_id, synced_at DESC
```

Changes to:
```sql
SELECT DISTINCT ON (retail_chain_id, store_id) ...
FROM store_sync_state
WHERE pipeline_name = $1
  AND (retail_chain_id, store_id) IN (($2,$3), ($4,$5), ...)
  AND sync_status = 'success'
ORDER BY retail_chain_id, store_id, synced_at DESC
```

The `IN` clause needs to be dynamically built from the `storeKeys` slice (pairs of `retail_chain_id` and `store_id`). The result map is keyed by `StoreKey`.

**Alternative** (simpler query, same result): use `ANY` with two parallel arrays:
```sql
WHERE pipeline_name = $1
  AND retail_chain_id = ANY($2)
  AND store_id = ANY($3)
  AND sync_status = 'success'
```

But this would match cross-products (chain A + store B). The tuple `IN` approach or a join on a VALUES list is correct. Since the store count is bounded (~100s), the dynamic `IN` is fine.

### State SQL: InsertStoreRun / BulkInsertStoreRuns

**File: `internal/state/postgres/postgres_state.go`**

Add `retail_chain_id` to the INSERT:
```sql
INSERT INTO store_sync_state (
    run_id, pipeline_name, retail_chain_id, store_id, sync_status, ...
) VALUES ($1, $2, $3, $4, $5, ...)
```

### Connector: thread retail_chain_id

**File: `internal/connector/vusion/sync.go`**

The `bufferedStore` struct already has `storeID`. Add `retailChainID`:

```go
type bufferedStore struct {
    data           models.Store
    apiStoreID     string
    storeID        string
    retailChainID  string  // NEW — from store["retailChainId"]
}
```

In Phase 1, extract `retailChainID` from the store map (the field is `retailChainId` in the API response, accessible as `store["retailChainId"]`).

The state lookup in Phase 2 changes from:
```go
storeIDs = append(storeIDs, storeID)
// ...
storeStates, err := conn.stateStore.GetLatestSuccessfulStoreRuns(ctx, pipelineName, storeIDs)
// ...
storeStates[storeID]
```

To:
```go
storeKeys = append(storeKeys, state.StoreKey{RetailChainID: retailChainID, StoreID: storeID})
// ...
storeStates, err := conn.stateStore.GetLatestSuccessfulStoreRuns(ctx, pipelineName, storeKeys)
// ...
storeStates[state.StoreKey{RetailChainID: bs.retailChainID, StoreID: bs.storeID}]
```

### Connector metrics: key by (retailChainID, storeID)

**File: `internal/connector/metrics.go`**

Currently `storeMetrics` is `sync.Map` keyed by `string` (store_id). After the fix, it needs a compound key.

Simplest approach: key by `"retail_chain_id:store_id"` string. This avoids changing the map type and keeps the `SyncMetrics` API simple. Define a helper:

```go
func storeMetricKey(retailChainID, storeID string) string {
    return retailChainID + ":" + storeID
}
```

Update `RegisterStore`, `IncrementStoreProducts`, etc. to accept both IDs.

**Alternative:** use `StoreKey` struct as map key (requires changing sync.Map usage). The string approach is simpler since `sync.Map` keys must be comparable.

### buildStoreRuns caller

**File: `cmd/eslorchestrator/run.go`**

`buildStoreRuns` iterates `storeMetrics` map to create `StoreSyncRun` structs. The map key changes from `storeID` to `"retailChainID:storeID"`. The function needs to split the key back, or the metrics API returns structured data.

Simplest: change `GetStoreMetrics()` to return a map keyed by a struct or change `buildStoreRuns` to parse the composite key. Since `StoreKey` is now defined in the state package, use it:

```go
func (m *SyncMetrics) GetStoreMetrics() map[state.StoreKey]*StoreEntityCounts
```

This creates a dependency from `connector` → `state` (for the `StoreKey` type). If that's undesirable, define the key type in `connector` and have `buildStoreRuns` convert. But `connector` already depends on `state` indirectly (the connector options accept `state.Store`), so this is fine.

### Mock updates

Regenerate mocks via `make mock-gen` after changing the `state.Store` interface.

### Test updates

- State postgres tests: update `InsertStoreRun`/`GetLatestSuccessfulStoreRuns` test cases with `RetailChainID`
- Sync tests: update mock expectations for the new signature
- Metrics tests: update `RegisterStore` etc. to pass both IDs
- run.go tests: update `buildStoreRuns` test data

## Implementation order

1. Modify V1.0.0.15 migration — add `retail_chain_id` column, populate, update index/trigger
2. Update datapipeline state struct/interface (`StoreKey`, `RetailChainID`)
3. Update state postgres implementation (SQL queries)
4. Regenerate mocks
5. Update connector (`bufferedStore`, state lookup, metrics)
6. Update `buildStoreRuns` caller in `run.go`
7. Update all tests
8. Verify: `make lint && go test ./... -short`

## Verification

- `make lint && go test ./... -short` — all unit tests pass
- `go test -tags=integration ./...` — integration tests pass (if applicable for state package)
- Confirm no `store_id`-only keying remains in state lookups or metrics
