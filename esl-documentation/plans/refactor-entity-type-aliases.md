# Plan: refactor-entity-type-aliases

**Scope:** esl-common type aliases + datapipeline adoption of `entity.EntityType` constants
**Depends on:** esl-common shared package (already done)
**Status:** Not started

## Context

The datapipeline uses hardcoded `"store"`, `"product"`, `"label"`, `"accesspoint"` strings in ~20 production code locations. The esl-common `entity` package provides constants for these. Adopting them gives a single source of truth and catches typos at compile time.

## Part A: esl-common — switch named types to type aliases

**Repo:** `/Users/joaopires/Projects/sonae/esl/common`

`EntityType` and `ChangeType` are currently named types (`type Foo string`), which require explicit `string()` casts at every boundary where a plain `string` is expected (metadata maps, telemetry attributes, etc.).

Go's standard approach for string enums is plain constants with no named type (e.g. `net/http.MethodGet`). Type aliases provide the same zero-friction behavior while preserving documentation value in function signatures.

### Changes

**`entity/keys.go`** — change named type to alias:

```go
// Before
type EntityType string

// After
type EntityType = string
```

Constants and `ConflictKeys` map are unchanged — they work identically with an alias.

**`event/types.go`** — change named type to alias + use `entity.EntityType`:

```go
// Before
type ChangeType string

// After
type ChangeType = string
```

Also update `ChangeEvent.EntityType` from `string` to `entity.EntityType` (free since it's now an alias):

```go
// Before
EntityType string `json:"entity_type"`

// After
EntityType entity.EntityType `json:"entity_type"`
```

### Verification

1. `go build ./...`
2. `go test ./...`

---

## Part B: datapipeline — adopt entity.EntityType constants

**Repo:** `/Users/joaopires/Projects/sonae/esl/datapipeline`

### Dependency

Add esl-common to `go.mod`. Requires authentication for the private repo. Ensure `GOPRIVATE` includes the org and SSH/token auth is configured:

```bash
GOPRIVATE=github.com/sonaemc-instore/* go get github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common@<latest-commit>
```

### Telemetry label inconsistency

sync.go line 297 uses `"access_point"` (with underscore) while every other telemetry attribute and the entity constant use no underscore (`"accesspoint"`, `"store"`, `"product"`, `"label"`). This plan standardizes it to `entity.AccessPoint` = `"accesspoint"`.

**Impact:** changes the `connector.entity` attribute value for access point read metrics. Dashboards/alerts filtering on `connector.entity="access_point"` would need updating.

### Files to modify

| # | File | Change |
|---|------|--------|
| 1 | `go.mod` / `go.sum` | Add esl-common dependency (latest commit on main) |
| 2 | `internal/connector/vusion/vusion.go` | Import `entity` pkg; change `createRecord` param to `entity.EntityType`; update 5 call sites |
| 3 | `internal/connector/vusion/sync.go` | Import `entity` pkg; update 1 `createRecord` call + 9 telemetry attributes |
| 4 | `internal/transformer/normalizer/normalizer.go` | Import `entity` pkg; use `entity.*` as strategy map keys |

### No changes to these files

- **Sink config/tests** — `Tables` map keys come from YAML config, not code. No hardcoded entity strings to replace in production sink code.
- **Test files** (`sync_test.go`, `fields_strategy_test.go`, `postgres_test.go`, `query_test.go`, `api_steps.go`) — these assert on or simulate specific string values. Changing them to use constants doesn't add value (tests should verify the actual values, not re-derive them from the same constants).

### Step-by-step changes

#### Step 1: Add esl-common dependency

```bash
GOPRIVATE=github.com/sonaemc-instore/* go get github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common@<latest-commit>
```

#### Step 2: Refactor `createRecord` in `vusion.go`

Change signature (no casts needed since `EntityType = string`):

```go
// Before
func (conn *vusionConnector) createRecord(source, id string, ...) *models.Record {

// After
func (conn *vusionConnector) createRecord(entityType entity.EntityType, id string, ...) *models.Record {
    // rename internal usage from `source` to `entityType`
    // metadata["type"] = entityType   (works directly, no cast)
    // Source: fmt.Sprintf("vusion-%s", entityType)  (works directly)
```

Update all call sites in `vusion.go` (5 occurrences):

| Line | Before | After |
|------|--------|-------|
| 108 | `"product"` | `entity.Product` |
| 130 | `"label"` | `entity.Label` |
| 153 | `"product"` | `entity.Product` |
| 174 | `"label"` | `entity.Label` |
| 345 | `"accesspoint"` | `entity.AccessPoint` |

#### Step 3: Update call site + telemetry in `sync.go`

Update `createRecord` call (1 occurrence):

| Line | Before | After |
|------|--------|-------|
| 93 | `"store"` | `entity.Store` |

Update telemetry attributes (9 occurrences) — no casts needed:

| Line | Before | After |
|------|--------|-------|
| 57 | `"store"` | `entity.Store` |
| 113 | `"store"` | `entity.Store` |
| 242 | `"product"` | `entity.Product` |
| 251 | `"product"` | `entity.Product` |
| 252 | `"product"` | `entity.Product` |
| 270 | `"label"` | `entity.Label` |
| 279 | `"label"` | `entity.Label` |
| 280 | `"label"` | `entity.Label` |
| 297 | `"access_point"` | `entity.AccessPoint` |

#### Step 4: Update normalizer strategy map in `normalizer.go`

No casts needed — `entity.Store` is just a `string`:

```go
// Before
strategies: map[string]TransformationStrategy{
    "store":       newFieldsStrategy(models.StoreFields),
    "accesspoint": newFieldsStrategy(models.AccessPointFields),
    "label":       newFieldsStrategy(models.LabelFields),
    "product":     newFieldsStrategy(models.ProductFields),
}

// After
strategies: map[string]TransformationStrategy{
    entity.Store:       newFieldsStrategy(models.StoreFields),
    entity.AccessPoint: newFieldsStrategy(models.AccessPointFields),
    entity.Label:       newFieldsStrategy(models.LabelFields),
    entity.Product:     newFieldsStrategy(models.ProductFields),
}
```

### Verification

1. `go build ./...` — compiles
2. `go test ./internal/connector/vusion/... -v -short` — connector unit tests pass
3. `go test ./internal/transformer/... -v -short` — normalizer tests pass
4. `go test ./... -v -short` — full project, no regressions
5. `make lint` — no new lint findings
