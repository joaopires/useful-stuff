# Plan: phase2-cdc-shared-package

**Scope:** New `esl-go-commons` repository
**Depends on:** Nothing (first to implement)

Shared Go package imported by both datapipeline and event-publisher:

```go
// outbox/types.go
type ChangeType string
const (
    ChangeTypeCreated  ChangeType = "CREATED"
    ChangeTypeModified ChangeType = "MODIFIED"
)

type ChangeEvent struct {
    EventType  ChangeType         `json:"event_type"`
    EntityType string             `json:"entity_type"`
    EntityKey  map[string]string  `json:"entity_key"`
    Payload    map[string]any     `json:"payload"`
    OccurredAt time.Time          `json:"occurred_at"`
}

// entities/keys.go
var EntityConflictKeys = map[string][]string{
    "store":       {"retail_chain_id", "store_id"},
    "product":     {"retail_chain_id", "store_id", "item_id"},
    "label":       {"store_id", "retail_chain_id", "label_id"},
    "accesspoint": {"retail_chain_id", "store_id", "id"},
}
```

## Verification

- `go build ./...`
- Unit tests for type serialization
