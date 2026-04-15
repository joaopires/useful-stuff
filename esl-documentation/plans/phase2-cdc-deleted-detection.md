# Plan: Phase 2 DELETED Event Detection

**Scope:** database, datapipeline, datafetch, event-publisher, Phase 2 documentation
**Depends on:** existing CDC infrastructure (datapipeline sink + outbox + event-publisher)
**Status:** Planning (draft 2026-04-15)

## Motivation

Phase 2 currently detects CREATED and UPDATED events only. DELETED detection was originally deferred to Phase 3 but is being pulled forward. `event.ChangeTypeDeleted` is already defined in esl-common but not emitted today.

**The gap** — `vlinkClient.doRequest` (`internal/connector/vusion/vlink/client.go:276-294`) never sets the `deleted` query parameter. Consequence: `StreamProductsModifiedSince`, `StreamLabelsModifiedSince`, `StreamAllProducts`, and `StreamAllLabels` all silently miss tombstones — VLink hides DELETED rows by default. A row that flips ACTIVE → DELETED in VLink lingers in the sink forever; today's incremental sync has no signal to evict it.

## Approach

**Soft-delete, driven by Vusion's `deletionDate` field (products; labels TBD by probe).**

### VLink API mechanics (verified empirically, pre-prod, store `bomdia_pt.009648`)

- `?deleted=true` is a **show-everything** toggle — it **adds** DELETED rows alongside ACTIVE rows. It does **not** restrict to deleted.
- Without it, deleted rows return `count=0` even when matched by search.
- Combined with `search=modificationDate:[<cursor> TO *]`, the date filter applies symmetrically to both populations. Tested across 7 cutoffs: `count(combined) == count(active) + count(deleted)` holds exactly every time.
- Lucene/ES query-string syntax — clauses combine with AND, e.g. `search=modificationDate:[X TO *] AND status:DELETED`.
- DELETED rows carry both `modificationDate` and `deletionDate` within ms of each other — reusing the existing `modificationDate` cursor for tombstones is safe.
- **Recommended request**: `?deleted=true&search=modificationDate:[<cursor> TO *]&includes=…,status,deletionDate`. One paginated walk returns both populations, no race window.
- Labels endpoint structure mirrors products (same paginated values/count shape, same auth, same includes pattern). A probe against pre-prod confirmed the endpoint returns DELETED rows when `deleted=true` is set.

### Status vocabulary differs per entity — critical for sink branching

| Entity | Status values | Tombstone signal |
|---|---|---|
| **Product** | `ACTIVE`, `DELETED` (binary) | `status == "DELETED"` OR `deletionDate != null` — always agree |
| **Label** | `SYNCHRONIZED`, `REGISTERED`, `UNREACHABLE`, `DELETED` (multi-state) | `status == "DELETED"` ONLY — `deletionDate` is unreliable for labels (observed NULL on confirmed-DELETED rows) |

**Only `DELETED` triggers the deletion event + deletion-mark flow.** Every other status value — for labels, `SYNCHRONIZED`, `REGISTERED`, `UNREACHABLE`, or any future additions Vusion may introduce — is a valid live state. The classifier treats them the same as any other business field value: transitions between non-`DELETED` statuses flow through the existing CREATED / UPDATED logic like any other field change.

**Implications:**

- The classifier has a single positive test: incoming `status == "DELETED"`. No whitelist of alive statuses, no enumeration of non-DELETED transitions.
- For labels, route on `status`, not `deletionDate` (unreliable). For products, either works. Using `status` for both gives a single canonical signal.
- For labels' `deletion_date` DB column: populate when Vusion provides the value, accept NULL when it doesn't. Informational metadata, not a detection signal.

### Watermark — already safe, no changes

- `StoreSyncRun.SyncedAt` is the pipeline's wall-clock start time (`internal/state/state.go:92-96`; set in `cmd/eslorchestrator/run.go:502`; read back in `internal/connector/vusion/sync.go:202`).
- Cursor never depends on response payload or sort order — adding `deleted=true` introduces no cursor-skew risk.
- `lookbackWindow` (`internal/connector/vusion/sync.go:203`) already provides safety overlap; CDC dedupes via diff, so the overlap is a no-op.

### Soft-delete storage model

Two timestamps per deletion, following the existing dual-timestamp convention (`creation_date` + `created_at`, `modification_date` + `last_updated_at`):

| Column | Role | Source |
|---|---|---|
| `deletion_date` | **Business timestamp** — when Vusion marked the record deleted | Vusion `deletionDate` field. Reliably populated for products; informational-only for labels (Vusion returns NULL even on confirmed-DELETED label rows) |
| `deleted_at` | **Audit timestamp** — when our pipeline processed the deletion | Batch timestamp, injected by the CDC classifier on the status transition to `DELETED` |

The record stays in the database with all fields intact; only `deletion_date` and `deleted_at` are populated. Hard DELETE SQL is never issued.

### Classification flow

```
Connector: Vusion responds with ACTIVE + DELETED rows (single paginated walk, deleted=true)
    │
    ▼
Transformer: standard field mapping (deletionDate → deletion_date for products;
             status always mapped)
    │
    ▼
Sink (CDC classifier):
  ├── existing.status != "DELETED"  AND incoming.status == "DELETED"
  │     → classify as DELETED
  │     → inject deleted_at = batchTimestamp into RawData
  │     → build payload from incoming record (final-state snapshot)
  ├── key not in DB                                      → CREATED (existing)
  ├── key in DB, other business fields differ            → UPDATED (existing)
  └── no change                                          → no event (existing)
    │
    ▼
PostgreSQL: UPSERT (writes status + deletion_date + deleted_at + last_updated_at)
            + INSERT event_outbox, same transaction
```

**Canonical detection signal: `status == "DELETED"` transition.** Works for both products and labels. Required for labels because `deletionDate` is unreliable there (empirically observed NULL on confirmed tombstones). Applied to products too for consistency. `deletion_date` is stored when Vusion provides it but is never used as a detection signal.

## Locked decisions

| Decision | Choice | Reason |
|---|---|---|
| Delete mode | **Soft delete** via `deletion_date` (business) + `deleted_at` (audit) | Preserves history; no hard DELETE SQL; mirrors existing audit pattern |
| Detection source | **Vusion deletion feed** via `deleted=true` on existing endpoints | Authoritative; no diff-based reconciliation |
| Entity scope | **Products + labels only** | Only these two have deletion lifecycles in Vusion |
| VLink endpoint shape | **Single endpoint, `deleted=true` flag** threaded through existing `Stream*` methods | No race window, half the HTTP traffic vs sibling-endpoint design |
| Full-sweep behaviour | **Pass `deleted=true` on `StreamAllProducts` / `StreamAllLabels` too** | First-contact sync emits DELETED events for historical tombstones; consumers get a complete snapshot on day one |
| Label schema | **Both entities get `deletion_date` + `deleted_at`**; for labels, `deletion_date` is informational only (Vusion populates unreliably) | Probe resolved: VLink labels endpoint does return `deletionDate` in its response, but the value is frequently NULL even on confirmed-DELETED rows |
| Atomicity | **Same transaction as CREATED/UPDATED** | UPSERT + outbox INSERT commit together |
| Classifier signal | **`status == "DELETED"` transition** (canonical for both entity types) | Required for labels (unreliable `deletionDate`); applied to products for consistency |
| Metrics | **Separate counters** — `ProductsDeleted`, `LabelsDeleted` alongside existing `ProductsProcessed`, `LabelsProcessed` | Observability distinguishes tombstone volume from live-data throughput |
| Datafetch visibility | `deletion_date` queryable (where present); `deleted_at` internal (excluded like `created_at` / `last_updated_at`) | Matches existing internal/external distinction |

## Proposed decision (please confirm or override)

### DELETED event payload shape

**Proposal:** Full snapshot of the record's final state — all business fields, `status: "DELETED"`, `deletion_date` (set for products; may be NULL for labels), `deleted_at` set. Same shape as CREATED; consumers receive everything needed to act on the deletion.

**Alternatives:**
- Minimal: `entity_key` + `status` + `deleted_at`
- Diff-style: `status: {old: "ACTIVE", new: "DELETED"}, deleted_at: T`

## Components affected

### `database`

#### New migration `V1.0.0.19__add_deletion_columns.sql`

```sql
-- Add deletion_date (business) to labels — products already has it (V1.0.0.07)
ALTER TABLE esl.labels ADD COLUMN deletion_date TIMESTAMPTZ;

-- Add deleted_at (audit) to both products and labels
ALTER TABLE esl.products ADD COLUMN deleted_at TIMESTAMPTZ;
ALTER TABLE esl.labels   ADD COLUMN deleted_at TIMESTAMPTZ;
```

For labels, `deletion_date` is populated when Vusion provides a value but may stay NULL for many tombstones. Detection does not depend on it — `status == "DELETED"` is the canonical signal.

Stores and access_points: no change (deletion not supported).

**Backfill consideration** — if pre-Phase-2 product rows already have `deletion_date` set, `deleted_at` will stay NULL. Optional one-line backfill at implementation time: `UPDATE esl.products SET deleted_at = deletion_date WHERE deletion_date IS NOT NULL AND deleted_at IS NULL`.

### `esl-common`

**No changes.** `event.ChangeTypeDeleted` exists.

### `datapipeline`

#### `internal/connector/vusion/vlink/client.go`

- **`doRequest` signature** (lines 276-294): accept a `deleted bool` parameter. When `true`, append `&deleted=true` to the query string.
- All internal callers (`getAllProducts`, `getAllLabels`, etc.) — thread the flag.

#### `internal/connector/vusion/vusion.go` + `vlink/client.go` (Stream methods)

- **Stream methods** (`StreamProductsModifiedSince`, `StreamLabelsModifiedSince`, `StreamAllProducts`, `StreamAllLabels`): accept or internally set `deleted=true`. Per locked decisions, **always** pass `deleted=true` — no conditional.
- Interface methods on `vlinkClient` interface updated.

#### `internal/connector/vusion/sync.go`

- **No structural changes** to `processStoreEntities`. Existing calls to product/label stream methods now receive ACTIVE + DELETED in one pass.
- **Metrics** (`StoreSyncRun`): extend with `ProductsDeleted`, `LabelsDeleted` counters. Increment them from the classifier or a lightweight counter wrapper once a record is classified as DELETED.

#### `internal/models/vlink.go`

- `status` is already in both `ProductFields` and `LabelFields`. Confirm during implementation.
- **`ProductFields`**: `deletionDate` already present (line 20). No change.
- **`LabelFields`**: **add `"deletionDate"`** — informational metadata only. Detection uses `status`, not `deletionDate`.

#### `internal/sink/postgres/config.go`

Add:
```go
ColDeletedAt  = "deleted_at"
ColStatus     = "status"  // if not already present
```

#### `internal/sink/postgres/cdc.go`

- **Extend the audit-comparison exclusion map** (`classifyAndDiff` guard around line 22-23): add `ColDeletedAt` so deletion-audit transitions don't produce spurious UPDATED events.
- **Extend `classifyAndDiff`** with the DELETED branch:
  - Before the existing CREATED/UPDATED decision, check `status` transition.
  - If existing record has `status != "DELETED"` **and** incoming has `status == "DELETED"` → classify DELETED.
  - Inject `record.RawData[ColDeletedAt] = batchTimestamp` so the UPSERT writes both columns together.
  - Build DELETED payload from the incoming record's final-state fields (per proposed decision).
- **Edge cases** to define during implementation:
  - Incoming `status == "DELETED"` and existing also `"DELETED"`: no event (already deleted).
  - Incoming non-`DELETED` status and existing `"DELETED"` (theoretical undelete): fall through to regular UPDATED classification — no explicit "resurrected" type.
  - Key not in DB but incoming `status == "DELETED"`: classify as CREATED-then-DELETED? Simplest: classify as DELETED (emit single DELETED event). Alternative: emit both CREATED and DELETED. Document the chosen behaviour.

#### `internal/sink/postgres/query.go`

- **Add `ColDeletedAt` to `excludeFromUpdate`** — once set, `deleted_at` must not be overwritten on subsequent upserts. (The classifier only injects `deleted_at` on the status transition; later benign UPDATES won't touch it either. Belt-and-suspenders.)

#### `internal/sink/postgres/write_batch.go`

- **No changes to `injectAuditTimestamps`.** It continues setting `created_at` + `last_updated_at` on every record. `deleted_at` is injected only by the CDC classifier for DELETED-classified records.

#### Tests

Unit (`cdc_test.go`):
- `status: ACTIVE → DELETED` transition emits DELETED event and injects `deleted_at = batchTimestamp`
- `status: DELETED → DELETED` emits no event
- `status: DELETED → ACTIVE` classifies as UPDATED (no special handling)
- `deleted_at` excluded from CDC comparison (doesn't produce spurious UPDATED events)
- Key-not-in-DB + incoming `status: DELETED` — verify chosen behaviour

Integration (`cdc_integration_test.go`):
- Seed a product with `status: ACTIVE, deletion_date: NULL, deleted_at: NULL`
- Process an incoming record with `status: DELETED, deletion_date: <time>`
- Verify DB row has `status, deletion_date, deleted_at` all populated; outbox has DELETED entry; payload matches final-state snapshot
- Same for labels (Branch A: with `deletion_date`; Branch B: without)

### `datafetch`

#### `internal/config/entities.yaml`

**Products:**
- Add `deleted_at` — timestamp, `internal: true`
- (`deletion_date` already present)

**Labels:**
- Add `deletion_date` — timestamp, regular (queryable; values may be NULL for tombstones)
- Add `deleted_at` — timestamp, `internal: true`

#### Schema validator
- Validates new columns and types on startup — passes automatically once the migration lands.

#### Tests
- `internal/config/entities_test.go`: no PK changes, but confirm column-count assertions still hold.

### `event-publisher`

#### `internal/transform/transform.go`

- **No code changes expected.** `strings.ToLower(ce.EventType)` produces `"deleted"`; topics render as `.../deleted/v1/...`. `flattenField` applies only to UPDATED events; DELETED passes through with business fields intact.

#### `internal/transform/transform_test.go`

- **Add `TestToPublishedEvent_Deleted`** covering topic segment and payload assembly for a DELETED event (both product and label shapes).

#### Everything else in event-publisher

- **No changes.** Polling, outbox reads, status updates, Solace publish are all event-type-agnostic.

### `k8s`

**No changes.** No new secrets, no netpol updates.

### Documentation

| File | Change |
|---|---|
| `phase-2/01-introduction.md` | Remove "DELETED event detection is deferred" from Scope and Glossary; mention DELETED in the component overview table |
| `phase-2/02-architecture.md` | Update text claiming only CREATED/UPDATED are handled; include DELETED in the data flow narrative |
| `phase-2/03-database.md` | Document V1.0.0.19; add `deletion_date` / `deleted_at` rows to products schema; add `deleted_at` (and `deletion_date` per branch) to labels schema; note stores / access_points have no deletion support |
| `phase-2/04-datapipeline.md` | New subsection **Deletion detection**: VLink `deleted=true` mechanics, scope (products + labels), dual-timestamp soft-delete pattern, `status == "DELETED"` transition classifier, no separate DELETE execution path, `ProductsDeleted` / `LabelsDeleted` metrics. Remove "No DELETED event detection" from Known Limitations |
| `phase-2/05-event-publisher.md` | Add DELETED event JSON example alongside CREATED; confirm topic table covers `deleted` as a `{messageType}` value |
| `plans/phase2-cdc-masterplan.md` | Add step 11 **DELETED event detection** in the Status table; add this plan to the Scoped Plans list |
| `plans/phase2-cdc-deleted-detection.md` | **This plan** (updates as decisions lock in and probe resolves) |

## Implementation order

1. **database**: write + apply `V1.0.0.19__add_deletion_columns.sql` (adds `deletion_date` to labels; `deleted_at` to products and labels). Optional products backfill.

2. **datapipeline `models/vlink.go`**:
   - Confirm `status` in both `ProductFields` and `LabelFields`
   - Add `"deletionDate"` to `LabelFields` (informational only)

3. **datapipeline `internal/sink/postgres/config.go`**: add `ColDeletedAt` constant (+ `ColStatus` if missing).

4. **datapipeline `internal/connector/vusion/vlink/client.go`**: extend `doRequest` signature with `deleted bool`; emit `&deleted=true` when set.

5. **datapipeline `internal/connector/vusion/vusion.go` + `vlink/client.go`**: thread `deleted=true` through `StreamProductsModifiedSince`, `StreamLabelsModifiedSince`, `StreamAllProducts`, `StreamAllLabels`. Update `vlinkClient` interface accordingly.

6. **datapipeline `internal/sink/postgres/cdc.go`**: extend audit-exclusion map; add DELETED branch to `classifyAndDiff`; inject `deleted_at` on the transition; handle edge cases.

7. **datapipeline `internal/sink/postgres/query.go`**: add `ColDeletedAt` to `excludeFromUpdate`.

8. **datapipeline sink tests**: unit + integration coverage for the DELETED path. Test both product and label shapes, including labels with `deletion_date: NULL` on a DELETED transition.

9. **datapipeline `internal/connector/vusion/sync.go`**: add `ProductsDeleted` / `LabelsDeleted` to `StoreSyncRun`; increment from classifier hook or counter wrapper.

10. **datafetch `entities.yaml`**: add `deleted_at` (internal) to products; add `deletion_date` (regular) + `deleted_at` (internal) to labels.

11. **event-publisher**: add `TestToPublishedEvent_Deleted` (product + label shapes).

12. **Documentation**: revise §01, §02, §03, §04, §05 per the table above. Update masterplan.

13. **Manual e2e verification in dev**:
    - Pick a test product + label in VLink
    - Have them marked DELETED via Vusion (or wait for a natural deletion)
    - Run datapipeline; verify DB rows have `status = "DELETED"`, `deleted_at` set, `deletion_date` set for products (may be NULL for labels)
    - Verify outbox has DELETED entries with correct entity_key and payload
    - Verify publisher delivers them to Solace with `deleted` message-type topic segment
    - Verify `ProductsDeleted` / `LabelsDeleted` metrics incremented
    - First-contact full-sweep scale check: on a fresh store, verify ~6,025 product tombstones and ~631 label tombstones (pre-prod numbers on `bomdia_pt.009648`) are accepted without sink backpressure

14. **Regenerate Phase 2 PDF** (batched with any other post-rollout polish; not blocking).

## Verification

- `make lint && make test && go test -tags=integration ./...` in datapipeline — 0 issues
- `make lint && make test && make test-integration` in datafetch — schema validator passes; new columns exposed
- `make lint && go test -tags=integration ./...` in event-publisher — 0 issues
- Manual e2e above

## Scope explicitly NOT covered

- **Hard delete** — rejected; soft-delete via audit + business columns
- **Stores or access_points deletion** — no Vusion deletion feed for those entity types
- **Undelete flow** — `status: DELETED → ACTIVE` treated as regular UPDATE; no explicit resurrected event type
- **Retention / purge of soft-deleted rows** — future housekeeping decision
- **Datafetch filtering of deleted rows** — consumers filter via `status` column (always present) or `deletion_date` (where applicable)

## Deliverables checklist

- [ ] Payload shape decision locked
- [ ] database: V1.0.0.19 migration merged (+ optional products backfill)
- [ ] datapipeline: client + stream methods + models + config + cdc + query + sync (metrics) + tests merged
- [ ] datafetch: entities.yaml updated for products + labels
- [ ] event-publisher: DELETED test case added
- [ ] Phase 2 docs (§01, §02, §03, §04, §05) updated
- [ ] Masterplan updated with step 11
- [ ] Manual e2e verification in dev env (including first-contact tombstone scale check)
