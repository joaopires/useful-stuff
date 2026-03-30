# Phase 2: CDC Event Detection — Master Plan

## Context

Phase 1 established a data pipeline that syncs ESL data from Vusion APIs into PostgreSQL via batched upserts. Phase 2 adds Change Data Capture: detecting CREATED and MODIFIED records during each pipeline execution and publishing events to Solace with guaranteed delivery and no duplications. DELETED events deferred to a later iteration.

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
  - Used by: datapipeline, event-publisher
  - Contains: outbox types, entity key definitions
```

## Key Decisions (resolved)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Change detection | Pre-fetch + in-Go classification | Diff payloads require old values → pre-fetch mandatory → classification is free |
| Delivery guarantee | Transactional outbox pattern | Atomic with upsert, decoupled publisher, no dual-write problem |
| Event payload | Diff (CREATED=full snapshot, MODIFIED=changed fields only) | User preference |
| `last_updated_at` | Unchanged behavior (always refreshes) | Internal audit only, no query changes needed |
| Repo layout | Separate repo + shared `esl-go-commons` package | Follows one-repo-per-component pattern, clean SRP |
| Solace topics | `esl/events/{entity_type}` | Event type in payload, not topic. Schema TBD |
| Feature flag | `cdc.enabled` in sink config | Safe rollout, existing behavior preserved when off |
| Comparison scope | All non-PK, non-audit columns | `created_at`/`last_updated_at` excluded; source `modification_date` included |

## Open Questions

- **Solace messaging mode:** Persistent (guaranteed, needs queue provisioning) or direct?
- **Outbox retention period:** 7 days? 30 days? Configurable per env?
- **`esl-go-commons` repo hosting:** Same GitHub org as other ESL repos? *(resolved: yes — `sonaemc-instore` org)*

## Implementation Order

```
1. esl-go-commons ──────────┐
                              ├──→ 3. DOCS: intro + architecture + database
2. database migrations ──────┘                │
                                              ├──→ 4. datapipeline CDC ──┐
                                              │                          │
                              5. go-solace-sdk ├──→ 6. event-publisher ──┤
                                              │                          │
                                              └──→ 7. DOCS: datapipeline ┤
                                                   8. DOCS: event-pub ───┤
                                                                         ├──→ 10. DOCS: deployment + ops
                                                   9. k8s helm ──────────┘
```

### Status

| # | Step | Status |
|---|------|--------|
| 1 | esl-go-commons (shared package) | Done |
| 2 | database migrations (outbox) | Done |
| 3 | DOCS: introduction, architecture, database | Done |
| 4 | datapipeline CDC | In progress (planning) |
| 5 | go-solace-sdk (Solace Go client library) | Done (Phases 1-4 + 6a complete — connection, telemetry, producer, integration tests, README; consumer phases 5/6b deferred to ESL Phase 3) |
| 6 | event-publisher | Not started |
| 7 | DOCS: data pipeline (CDC additions) | Not started |
| 8 | DOCS: event publisher | Not started |
| 9 | k8s helm | Not started |
| 10 | DOCS: deployment, operations | Not started |

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
| event-publisher | Event Publisher (new section) |
| k8s-helm | Deployment, Operations |

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

- [phase2-cdc-shared-package.md](phase2-cdc-shared-package.md) — esl-go-commons repo
- [phase2-cdc-database.md](phase2-cdc-database.md) — Flyway migrations for outbox table
- [phase2-cdc-datapipeline.md](phase2-cdc-datapipeline.md) — CDC detection in the sink
- [go-solace-sdk-implementation.md](/Users/joaopires/Projects/sonae/esl/plans/go-solace-sdk-implementation.md) — Solace Go client library (separate repo)
- [phase2-cdc-event-publisher.md](phase2-cdc-event-publisher.md) — New publisher service
- [phase2-cdc-k8s-helm.md](phase2-cdc-k8s-helm.md) — Helm chart changes
