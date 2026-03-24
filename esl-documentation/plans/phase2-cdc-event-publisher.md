# Plan: phase2-cdc-event-publisher

**Scope:** New `event-publisher` repository
**Depends on:** shared package, database migrations

## Architecture

Long-running Go service deployed as K8s Deployment. Polls the outbox table and publishes to Solace.

## Core loop

```
Poll (1s interval) → SELECT undelivered events (FOR UPDATE SKIP LOCKED)
  → Publish each to Solace topic esl/events/{entity_type}
  → UPDATE delivered_at = NOW() for published event IDs
  → Commit transaction
```

## Components

- `cmd/eventpublisher/main.go` — CLI entry, signal handling, graceful shutdown
- `internal/publisher/publisher.go` — polling loop, batch processing
- `internal/publisher/config.go` — config (poll interval, batch size, DB, Solace)
- `internal/solace/client.go` — Solace client wrapper (persistent messaging)
- `internal/health/health.go` — `/health` and `/ready` endpoints

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

## Verification

- **Unit tests:** polling logic with mock DB, Solace publish mock
- **Integration tests (testcontainers):** insert outbox rows → publisher picks up → marks delivered
- Health endpoint responds correctly when DB/Solace connected vs disconnected
