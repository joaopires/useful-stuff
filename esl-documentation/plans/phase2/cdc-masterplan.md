# Phase 2: CDC Event Detection — Master Plan

## Context

Phase 1 established a data pipeline that syncs ESL data from Vusion APIs into PostgreSQL via batched upserts. Phase 2 adds Change Data Capture: detecting CREATED, UPDATED, and DELETED records during each pipeline execution and publishing events to Solace with guaranteed delivery and no duplications.

## Architecture

```
[Existing Pipeline]                        [New Components]
Connector → Transformer → Sink ──┐
                                  │  same DB transaction
                          ┌──────┴──────┐
                          │  PostgreSQL  │
                          │  ┌────────┐  │
                          │  │ tables  │  │
                          │  ├────────┤  │
                          │  │ outbox  │  │
                          │  └───┬────┘  │
                          └──────┼──────┘
                                 │ poll
                     ┌───────────┴───────────┐
                     │    Event Publisher     │
                     │  (separate repo,       │──→ Solace
                     │   K8s Deployment)      │    topic: esl/events/{entity}
                     └───────────────────────┘

[Shared Go Package: esl-go-commons]
  - Used by: datapipeline, event-publisher, datafetch
  - Contains: outbox types, entity key definitions,
              postgres pool config + creation, error classification
```

## Key Decisions (resolved)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Change detection | Pre-fetch + in-Go classification | Diff payloads require old values → pre-fetch mandatory → classification is free |
| Delivery guarantee | Transactional outbox pattern | Atomic with upsert, decoupled publisher, no dual-write problem |
| Event payload | Diff (CREATED=full snapshot, UPDATED=changed fields only) | User preference |
| `last_updated_at` | Unchanged behavior (always refreshes) | Internal audit only, no query changes needed |
| Repo layout | Separate repo + shared `esl-go-commons` package | Follows one-repo-per-component pattern, clean SRP |
| Solace topics | `esl/events/{entity_type}` | Event type in payload, not topic. Schema TBD |
| Feature flag | `cdc.enabled` in sink config | Safe rollout, existing behavior preserved when off |
| Comparison scope | All non-PK, non-audit columns | `created_at`/`last_updated_at` excluded from comparison; conflict keys excluded (in `EntityKey`); source `modification_date` included |
| Type comparison strategy | `::TEXT` cast in SELECT + string normalization | Avoids pgtype vs native Go type mismatches (e.g. `int32` vs `float64`, `time.Time` vs `string`). Both sides normalized to string for comparison. |
| Single-writer assumption | READ COMMITTED (default isolation) | The datapipeline is the sole writer to entity tables. No concurrent writes means no risk of missed diffs between SELECT and upsert within the CDC transaction. If another service starts writing to entity tables, revisit isolation level (SERIALIZABLE or row-level locking). |
| CDC conflict keys | `entity.ConflictKeys` from esl-common | Single source of truth for entity business keys in CDC. YAML `TableConfig.ConflictKeys` stays only for the upsert `ON CONFLICT` clause (follow-up: unify). |
| Outbox status tracking | Explicit `status` column (`PENDING`, `DELIVERED`, `FAILED`) | Enables failure tracking and observability; `delivered_at` kept for timestamp |
| Outbox consumption | Polling (`FOR UPDATE SKIP LOCKED`) over WAL logical replication | Simpler ops (no `wal_level=logical`, no replication slots, no WAL bloat risk), sufficient latency (1s), free observability via `status` column; WAL streaming better suited for high-throughput/low-latency scenarios |

## Open Questions

- **Outbox retention period:** 7 days? 30 days? Configurable per env? *(V1.0.0.18 ships with 7-day default via `esl.cleanup_delivered_events(retention_days INT DEFAULT 7)`; per-env tuning can follow rollout observations)*
- **`esl-go-commons` repo hosting:** Same GitHub org as other ESL repos? *(resolved: yes — `sonaemc-instore` org)*
- **Solace messaging mode:** *(resolved: persistent/guaranteed. Event-publisher uses `PublishMessageConfirmed` with go-solace-sdk internal retries — see §05-event-publisher.md. Direct mode was ruled out: the outbox pattern guarantees at-least-once end-to-end, which persistent delivery preserves and direct would undermine.)*

## Implementation Order

```
1. esl-go-commons ──────────┐
                              ├──→ 3. DOCS: intro + architecture + database
2. database migrations ──────┘                │
                                              │
               1b. esl-go-commons: postgres ──┼──→ 4a. entity type aliases ──┐
                                              │                               ├──→ 4c. datapipeline CDC ──┐
                                              │    4b. adopt common postgres ─┘                            │
                                              │                                                            │
                              5. go-solace-sdk ├──→ 6. event-publisher ────────────────────────────────────┤
                                              │                                                            │
                                              └──→ 7. DOCS: datapipeline ─────────────────────────────────┤
                                                   8. DOCS: event-pub ────────────────────────────────────┤
                                                                                                           ├──→ 10. DOCS: deployment + ops
                                                   9. k8s helm ───────────────────────────────────────────┘
```

### Status

| # | Step | Status |
|---|------|--------|
| 1 | esl-go-commons (shared package) | Done |
| 1b | esl-go-commons: postgres package (pool + error classification) | Done |
| 2 | database migrations (outbox) | Done |
| 3 | DOCS: introduction, architecture, database | Done |
| 4a | datapipeline: replace entity strings with esl-common constants | Done (2026-04-06, commit 42a6a7e) |
| 4b | datapipeline: adopt esl-common postgres package | Done (2026-04-06, commit 2bae4c5) |
| 4c | datapipeline CDC | Done (2026-04-06, commit 1704dd2 + timestamp fix 2c4bd21) |
| 5 | go-solace-sdk (Solace Go client library) | Done (Phases 1-4 + 6a complete — connection, telemetry, producer, integration tests, README; consumer phases 5/6b deferred to ESL Phase 3) |
| 5b | database migration: add `status` column to outbox | Done (2026-04-06, commit 0fc580c) |
| 6 | event-publisher | Done (2026-04-09) |
| 6b | refactor: outbox UUID primary key (database, datapipeline, event-publisher) | Done (2026-04-09) |
| 6d | fix: explicit audit timestamps in CDC outbox payload | Done (2026-04-10, commit 94bbd83) |
| 6c | refactor: extract shared constants & fix composite store IDs | Done (2026-04-15) |
| 6e | fix: add retail_chain_id to store_sync_state | Done (2026-04-10) |
| 7 | DOCS: data pipeline (CDC additions) | Done (2026-04-10) |
| 8 | DOCS: event publisher | Done (2026-04-10) |
| 9 | k8s helm | PR open (2026-04-15, k8s PR #30) |
| 10 | DOCS: deployment, operations | Done (2026-04-15) |
| 11 | DELETED event detection (pulled forward from Phase 3) | Done (2026-04-16) — database, datapipeline, datafetch, event-publisher, docs merged; e2e pending |
| 12a | go-solace-sdk: OAuth2 E2E test (Keycloak + Solace) | Done (2026-04-23, commit 63525b5) — per [event-publisher-oauth2.md](../event-publisher-oauth2.md) Phase A |
| 12b | event-publisher: adopt OAuth2 (`auth_scheme` config) | Pending — per [event-publisher-oauth2.md](../event-publisher-oauth2.md) Phase B; requires SDK bump to ≥ 63525b5 |

## Documentation

After completing each scoped plan's implementation (with user supervision), produce Phase 2 documentation inside `esl-documentation/phase-2/`, following the same structure as `phase-1/`:

- All files live under `esl-documentation/phase-2/`
- Separate markdown files per section (`NN-<section>.md`)
- Front matter only in `01-introduction.md`
- Diagrams in `esl-documentation/phase-2/diagrams/` (Excalidraw → SVG)
- PDF generation via the existing pandoc + typst pipeline

Documentation should be written incrementally — each completed scoped plan produces or updates the relevant section(s) rather than deferring all docs to the end.

| Scoped plan completed | Documentation sections to produce/update |
|---|---|
| shared-package + database | Introduction, Architecture overview, Database |
| datapipeline CDC | Data Pipeline (CDC additions) |
| go-solace-sdk | N/A (standalone repo, own README) |
| event-publisher | Event Publisher (new section) — include a decision rationale subsection explaining polling vs WAL streaming trade-offs and why polling was chosen |
| k8s-helm | Deployment, Operations |

## Post-implementation

1. **Tag esl-common** — once all consumers (datapipeline, datafetch, event-publisher) are stable, create a semver tag (e.g. `v0.2.0`) and update all `go.mod` references from commit hashes to the tag
2. **Tag go-solace-sdk** — same approach, create a semver tag and reference it from event-publisher's `go.mod`

## Conventions

- **Integration tests use `TestMain`**: When integration tests share an expensive resource (e.g. a Testcontainers container), use `TestMain(m *testing.M)` for setup/teardown and a package-level variable to hold the shared resource. Each test must be an independent top-level `TestXxx` function, not a subtest under a parent. This ensures output streams in real time and tests can be run individually.

## Repositories

| Component | Local Path |
|-----------|------------|
| esl-go-commons | `/Users/joaopires/Projects/sonae/esl/common` |
| database | `/Users/joaopires/Projects/sonae/esl/database` |
| datapipeline | `/Users/joaopires/Projects/sonae/esl/datapipeline` |
| go-solace-sdk | `/Users/joaopires/Projects/sonae/esl/go-solace-sdk` |
| event-publisher | `/Users/joaopires/Projects/sonae/esl/event-publisher` |
| k8s helm | `/Users/joaopires/Projects/sonae/esl/k8s` |

## Scoped Plans

- [cdc-shared-package.md](cdc-shared-package.md) — esl-go-commons repo (entity types, event types)
- [cdc-postgres-package.md](cdc-postgres-package.md) — esl-go-commons postgres package (pool config, error classification)
- [cdc-database.md](cdc-database.md) — Flyway migrations for outbox table
- [entity-type-aliases.md](../refactors/entity-type-aliases.md) — esl-common type aliases + datapipeline entity constant adoption
- [adopt-common-postgres.md](../refactors/adopt-common-postgres.md) — datapipeline: adopt esl-common postgres package (pool + errors + test fix)
- [cdc-datapipeline.md](cdc-datapipeline.md) — CDC detection in the sink
- [go-solace-sdk-implementation.md](../go-solace-sdk-implementation.md) — Solace Go client library (separate repo)
- [cdc-event-publisher.md](cdc-event-publisher.md) — New publisher service
- [outbox-uuid-primary-key.md](../refactors/outbox-uuid-primary-key.md) — Change outbox id from BIGSERIAL to UUID for deterministic eventId and at-least-once deduplication
- [cdc-explicit-timestamps.md](cdc-explicit-timestamps.md) — Explicit audit timestamps for entity/outbox consistency
- [extract-shared-constants.md](../refactors/extract-shared-constants.md) — Extract entity field names + fix composite store IDs
- [store-sync-state-retail-chain.md](../refactors/store-sync-state-retail-chain.md) — Add retail_chain_id to store_sync_state (required after store ID stripping)
- [cdc-k8s-helm.md](cdc-k8s-helm.md) — Helm chart changes
- [cdc-deleted-detection.md](cdc-deleted-detection.md) — DELETED event detection for products + labels via Vusion `deleted=true` flag, soft-delete (`deletion_date` + `deleted_at`)
