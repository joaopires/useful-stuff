# Plan: phase2-cdc-event-publisher

**Scope:** New `event-publisher` repository
**Depends on:** shared package (esl-common latest commit on main — includes `entity`, `event`, and `postgres` packages), database migrations

## Architecture

Long-running Go service deployed as K8s Deployment. Polls the outbox table and publishes to Solace.

## Core loop

```
Poll (1s interval) → SELECT WHERE status = 'PENDING' (FOR UPDATE SKIP LOCKED)
  → Validate entity_type against entity.EntityType enum
  → Publish each to Solace topic esl/events/{entity_type}
  → UPDATE status = 'DELIVERED', delivered_at = NOW() for published event IDs
  → On permanent failure: UPDATE status = 'FAILED' (after max retries)
  → Commit transaction
```

**Note:** Use `entity.EntityType` from esl-common when reading `entity_type` from the outbox table and when building Solace topic names. This provides compile-time safety and consistency with the datapipeline.

## Event transformation

The outbox row (`event.ChangeEvent`) is transformed into a flat published event before sending to Solace:

1. Generate `eventId` (UUID v4)
2. Merge `EntityKey` fields as top-level keys (e.g. `retail_chain_id`, `store_id`, `item_id`)
3. Merge `Payload` fields as top-level keys (all entity-specific data)
4. Set `send_date` to current time (ISO 8601)

The resulting event is a flat JSON object matching the client-provided schemas (Store, Product, Label, AccessPoint). The `EventType` and `EntityType` fields from the outbox row are not included in the published event — `EntityType` is used for topic routing (`esl/events/{entity_type}`).

**Note:** Only `CREATED` and `UPDATED` events are handled in Phase 2. The `DELETED` change type exists in esl-common but the event-publisher should ignore it (skip or log a warning) until a later iteration implements delete detection.

## Components

- `cmd/eventpublisher/main.go` — CLI entry, signal handling, graceful shutdown
- `internal/publisher/publisher.go` — polling loop, batch processing
- `internal/publisher/config.go` — config (poll interval, batch size, DB, Solace)
- `internal/solace/client.go` — Solace client wrapper (persistent messaging)
- `internal/health/health.go` — `/health` and `/ready` endpoints

## Database connection

Use `postgres.PoolConfig` and `postgres.NewPool` from esl-common for pool creation. The service maps its own YAML config to `postgres.PoolConfig`. Use `postgres.ClassifyError` and `postgres.IsTransient` for error handling and retry decisions.

## Config structure

```yaml
database:
  host, port, user, password, name, schema, ssl_mode
solace:
  host, vpn, username, password
  topic_prefix: "esl/events"
publisher:
  poll_interval: "1s"
  batch_size: 100
```

## Code quality: golangci-lint

Follow the same approach as `esl-common`:

- Add `.golangci.yml` (v2 format) with: `errcheck`, `gosec`, `staticcheck`, `ineffassign`, and `gofumpt` formatter
- Makefile with `GOLANGCI_LINT_VERSION` variable, `install-lint` target (pinned version, auto-install), and `lint` target depending on `install-lint`
- `make lint` must pass with 0 issues

## Verification

- **Unit tests:** polling logic with mock DB, Solace publish mock
- **Integration tests (testcontainers):** insert outbox rows → publisher picks up → marks delivered
- Health endpoint responds correctly when DB/Solace connected vs disconnected

---

## Post-implementation note

After the event-publisher implementation is complete and the esl-common code has been validated in practice, check whether a new esl-common tag (e.g. `v0.2.0`) should be created and referenced in `go.mod` instead of a commit hash.
