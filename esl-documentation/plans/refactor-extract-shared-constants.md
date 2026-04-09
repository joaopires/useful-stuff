# Refactor: Extract Shared Constants & Mappings to esl-common

**Scope:** esl-common, datapipeline, datafetch, event-publisher
**Depends on:** event-publisher implementation (step 6 complete)

## Motivation

Entity key field names (`"store_id"`, `"retail_chain_id"`, etc.), topic segment mappings, and the composite store ID format are duplicated as raw string literals across datapipeline, datafetch, and event-publisher. Centralizing them in esl-common eliminates drift and gives compile-time safety.

## What to extract

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

### 2. Topic segment mapping

The mapping from `entity.EntityType` to Solace topic segments is a property of entity types, not of the event-publisher alone. Future consumers (Phase 3) will also need it.

```go
// entity/topic.go
var TopicSegment = map[EntityType]string{
    Store:       "stores/store",
    Product:     "products/product",
    Label:       "labels/label",
    AccessPoint: "accesspoints/accesspoint",
}
```

**Consumers to update:**
- event-publisher: `internal/transform/transform.go` (remove local mapping, use `entity.TopicSegment`)

### 3. Table name mapping

The mapping from entity type to database table name is hardcoded in datapipeline's sink config. Centralizing it allows event-publisher integration tests and future services to reference it.

```go
// entity/tables.go
var TableName = map[EntityType]string{
    Store:       "stores",
    Product:     "products",
    Label:       "labels",
    AccessPoint: "access_points",
}
```

**Consumers to update:**
- datapipeline: `internal/sink/postgres/config.go` (use `entity.TableName` instead of hardcoded strings)

### 4. Composite store ID helpers

The datapipeline builds composite store IDs as `{retail_chain_id}.{store_id}`, and the event-publisher splits them. This format is a shared convention.

```go
// entity/storeid.go

// ComposeStoreID builds the composite "{retail_chain_id}_{store_id}" format.
func ComposeStoreID(retailChainID, storeID string) string

// SplitStoreID extracts the store portion from a composite store ID.
// Returns an error if the format is invalid.
func SplitStoreID(composite string) (retailChainID, storeID string, err error)
```

**Consumers to update:**
- datapipeline: wherever the composite is built (connector/sync)
- event-publisher: `internal/transform/transform.go` (replace local `splitStoreID`)

## What NOT to extract

- **Outbox status constants** (`PENDING`, `DELIVERED`, `FAILED`) — only used by event-publisher. Extract only if a second consumer appears.
- **`send_date` / `eventId` field names** — publisher-specific payload fields, not a shared concern.

## Implementation order

1. Add constants, mappings, and helpers to esl-common → tag new version
2. Update datapipeline → verify `make lint && go test -tags=integration ./...`
3. Update datafetch → verify `make lint && go test -tags=integration ./...`
4. Update event-publisher → verify `make lint && go test -tags=integration ./...`

## Verification

Each repository: `make lint && go test -tags=integration ./...` must pass with 0 issues after the update.
