# Plan: phase2-cdc-shared-package ✅

**Status:** Complete — v0.1.0 released 2026-03-25
**Scope:** `esl-common` repository (`github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common`)
**Depends on:** Nothing (first to implement)

Shared Go module (`esl-common`) imported by both datapipeline and event-publisher.

### Packages

**`event/`** — CDC event types:
- `ChangeType` — string enum (`CREATED`, `MODIFIED`)
- `ChangeEvent` — struct with `event_type`, `entity_type`, `entity_key`, `payload`, `occurred_at`

**`entity/`** — Entity type enum and key definitions:
- `EntityType` — string enum (`Store`, `Product`, `Label`, `AccessPoint`)
- `ConflictKeys` — maps `EntityType` to composite business key columns

### Import path

```go
import (
    "github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common/event"
    "github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common/entity"
)
```

## Verification

- `go build ./...`
- Unit tests for type serialization (`event/types_test.go`, `entity/keys_test.go`)
