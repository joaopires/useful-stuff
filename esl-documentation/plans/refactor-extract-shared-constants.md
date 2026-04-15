# Refactor: Extract Shared Constants & Fix Composite Store IDs

**Scope:** esl-common, datapipeline, datafetch, event-publisher, database, documentation
**Depends on:** event-publisher implementation (step 6 complete)
**Status:** Done (esl-common, database migration, datapipeline, datafetch, event-publisher, Phase 2 docs all complete)

**Follow-up:** [fix-store-sync-state-retail-chain.md](fix-store-sync-state-retail-chain.md) — the store ID stripping creates a collision risk in `store_sync_state` that requires adding `retail_chain_id` to the table. Must be completed before deployment.

## Motivation

Two problems:

1. **String literal duplication** — Entity key field names (`"store_id"`, `"retail_chain_id"`, etc.) are scattered as raw strings across datapipeline, datafetch, and event-publisher. Centralizing them in esl-common gives compile-time safety and eliminates drift.

2. **Composite store IDs in the database** — The Vusion API provides `storeId` in composite format (`continente_pt.000010`), which includes the retail chain as a prefix. The datapipeline stores this value as-is in the `store_id` column. This is redundant (`retail_chain_id` is already a separate column) and forces the event-publisher to split the composite at publish time. The fix is to strip the prefix at ingestion, so the database stores only the store portion (`000010`).

## What to extract to esl-common

### 1. Entity key field name constants

`entity.ConflictKeys` already lists field names per entity type, but consumers still use raw strings. Add named constants:

```go
// entity/fields.go
const (
    FieldRetailChainID = "retail_chain_id"
    FieldStoreID       = "store_id"
    FieldItemID        = "item_id"
    FieldLabelID       = "label_id"
    FieldAccessPointID = "id"
)
```

**Consumers to update:**
- datapipeline: `internal/connector/vusion/sync.go`, `internal/connector/vusion/vlink/client.go`, `internal/sink/postgres/cdc_test.go`, `internal/sink/postgres/cdc_integration_test.go`, `internal/transformer/normalizer/fields_strategy_test.go`
- datafetch: `internal/service/datafetch_test.go`, `internal/model/search_test.go`, `internal/adapters/http/handler_test.go`, `internal/config/entities_test.go`
- event-publisher: `internal/transform/transform.go`

## Store ID fix

### Problem flow (current)

```
Vusion API → storeId: "continente_pt.000010"
    │
    ▼
Transformer → store_id: "continente_pt.000010"  (key renamed, value untouched)
    │
    ▼
Database → store_id = "continente_pt.000010"     (redundant: retail_chain_id already = "continente_pt")
    │
    ▼
CDC outbox → entity_key.store_id = "continente_pt.000010"
    │
    ▼
Event Publisher → splitStoreID("continente_pt.000010") → "000010"  (workaround)
```

### Fixed flow

```
Vusion API → storeId: "continente_pt.000010"
    │
    ▼
Connector → strips prefix → storeId: "000010"   (before record building)
    │
    ▼  (VLink API calls still use the original composite for the URL path)
    │
Transformer → store_id: "000010"
    │
    ▼
Database → store_id = "000010"
    │
    ▼
CDC outbox → entity_key.store_id = "000010"
    │
    ▼
Event Publisher → uses store_id directly         (splitStoreID removed)
```

### Database migration

A Flyway migration strips the retail chain prefix from all `store_id` values. Since Flyway runs as a PreSync job in ArgoCD, this executes **before** the updated datapipeline and event-publisher deploy — no coordination needed.

**Tables to update:**

| Table | Column | Type | Notes |
|---|---|---|---|
| `esl.stores` | `store_id` | VARCHAR (PK) | `"continente_pt.000010"` → `"000010"` |
| `esl.products` | `store_id` | VARCHAR (PK) | Same |
| `esl.labels` | `store_id` | VARCHAR (PK) | Same |
| `esl.access_points` | `store_id` | VARCHAR (PK) | Same |
| `esl.store_sync_state` | `store_id` | VARCHAR (PK) | Same |
| `esl.event_outbox` | `entity_key` | JSONB | Strip prefix from `store_id` value inside the JSON |

**Migration logic:** For VARCHAR columns, split on `'.'` and take the second part. For the outbox JSONB column, update the `store_id` key inside `entity_key` using `jsonb_set`. Only rows where `store_id` contains a `'.'` are updated (idempotent — safe to re-run).

**Migration file:** `V1.0.0.18__strip_composite_store_id.sql` in the database repo.

### Datapipeline changes

**Connector: `internal/connector/vusion/vusion.go`**

Add a helper to strip the retail chain prefix from the Vusion API's composite `storeId`:

```go
// stripStoreIDPrefix extracts the store portion from a composite
// "{retail_chain_id}.{store_id}" value returned by the Vusion API.
// Example: "continente_pt.000010" → "000010"
func stripStoreIDPrefix(composite string) (string, error) {
    parts := strings.SplitN(composite, ".", 2)
    if len(parts) != 2 || parts[1] == "" {
        return "", fmt.Errorf("invalid composite storeId format: %q", composite)
    }
    return parts[1], nil
}
```

**Record building path** — Before building records (stores, products, labels, access points), replace the composite `storeId` value with the stripped version in the raw data map. The exact injection points:

- **Stores:** In the store processing loop in `sync.go`, after extracting the store from the API response. Replace the raw store map's `storeId` field before passing to the transformer.
- **Products/Labels:** The VLink API response for each product/label includes `storeId`. After fetching, replace the value in each record's raw data before building the record.
- **Access Points:** In `extractAccessPoints` (`vusion.go`), the connector copies `storeId` from the parent store into each transmitter's data map (line ~333: `data["storeId"] = storeID`). Change this to use the stripped value.

**VLink API calls** — The VLink client calls URLs like `/stores/{storeId}/productLabelling/products`. These URLs require the **original composite** value from the API. The `extractStoreID` function (which reads the raw `storeId` from the API response) must continue returning the composite for this purpose.

Separation:
- `extractStoreID(store)` → returns **composite** (for API URLs only)
- `stripStoreIDPrefix(composite)` → returns **clean** (for record data, sync state, logging)

**Sync state** — In `sync.go`, the store IDs used for `GetLatestSuccessfulStoreRuns` and `InsertStoreRun` must use the stripped value. Change from:

```go
storeID, _ := extractStoreID(store)
```

To:

```go
apiStoreID, _ := extractStoreID(store)       // composite — for VLink API calls
storeID, _ := stripStoreIDPrefix(apiStoreID)  // clean — for storage, state, logging
```

This matches the migrated `store_sync_state` table which will already have clean IDs by the time the updated datapipeline runs (Flyway PreSync guarantees this).

### Event-publisher changes

**`internal/transform/transform.go`:**

- Remove `splitStoreID` function entirely
- Remove the `splitStoreID(rawStoreID)` call in `ToPublishedEvent`
- Use `ce.EntityKey["store_id"]` directly — it's already the clean value

**`internal/transform/transform_test.go`:**

- Update all test fixtures: `"store_id": "continente_pt.000010"` → `"store_id": "000010"`
- Remove `TestSplitStoreID` test
- Remove `splitStoreID` edge case tests (`no_dot`, `trailing_dot`)

## What NOT to extract

- **Topic segment mapping** (`Store → "stores/store"`, etc.) — only event-publisher uses it today. Extract when a second consumer appears (Phase 3).
- **Table name mapping** (`Store → "stores"`, etc.) — datapipeline reads table names from YAML config; adding to esl-common would create a second source of truth without eliminating the first.
- **Outbox status constants** (`PENDING`, `DELIVERED`, `FAILED`) — only used by event-publisher. Extract only if a second consumer appears.
- **`send_date` / `eventId` field names** — publisher-specific payload fields, not a shared concern.
- **`stripStoreIDPrefix` in esl-common** — Only the datapipeline needs it (stripping at ingestion). The event-publisher no longer splits. If another ingestion service appears, extract then.

## Documentation changes

### Phase 2 docs (`esl-documentation/phase-2/`)

**`04-datapipeline.md`:**
- Add a note explaining the store ID normalization: the Vusion API provides composite `storeId` values (`{retail_chain_id}.{store_id}`), and the connector strips the prefix at ingestion so only the store portion is stored
- Mention this is a data correction from Phase 1 where the composite was stored as-is

**`05-event-publisher.md`:**
- Remove the "Store ID splitting" subsection under Event Transformation
- Simplify the transform description: `store_id` is used directly from the entity key
- Update the example published event if it shows a split
- Remove store ID splitting from "Solace Publishing" topic variable table if referenced

### Datapipeline repo docs

**`docs/postgres-sink.md`** (if it mentions store_id format) — update to reflect clean IDs.

**Config examples** (`examples/*.yaml`, `config-*.yaml`) — verify no composite store_id values in examples.

## Implementation order

1. Add field name constants to esl-common (`entity/fields.go`) → push, tag
2. Database migration (`V1.0.0.18__strip_composite_store_id.sql`) → push to main
3. Update datapipeline:
   a. Add `stripStoreIDPrefix` to connector
   b. Strip store_id at record building for all entity types
   c. Use clean store_id for sync state lookups and inserts
   d. Adopt field name constants from esl-common
   e. Update internal docs/config if affected
   f. Verify: `make lint && go test -tags=integration ./...`
4. Update datafetch — adopt field name constants → verify: `make lint && go test -tags=integration ./...`
5. Update event-publisher:
   a. Remove `splitStoreID` and all references
   b. Adopt field name constants from esl-common
   c. Update test fixtures
   d. Verify: `make lint && go test -tags=integration ./...`
6. Update Phase 2 documentation (`04-datapipeline.md`, `05-event-publisher.md`)

**Deployment:** Step 6e ([fix-store-sync-state-retail-chain.md](fix-store-sync-state-retail-chain.md)) must be completed before deployment — it modifies the same V1.0.0.15 migration and the datapipeline state code. ArgoCD handles the rest: Flyway (step 2) runs as PreSync before the datapipeline (step 3) and event-publisher (step 5) deploy.

## Verification

Each repository: `make lint && go test -tags=integration ./...` must pass with 0 issues after the update.

After deployment: verify that the database contains only clean `store_id` values (no dots) across all entity tables, `store_sync_state`, and outbox `entity_key`.
