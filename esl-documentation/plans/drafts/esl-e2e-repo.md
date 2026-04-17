# ESL E2E Test Repository — Plan

## Context

The datapipeline repo currently hosts a `godog-e2e/` directory with BDD tests that mix two concerns:

1. **CLI tests** — validate `eslorchestrator` commands (config validation, run success/failure). These test datapipeline internals and belong with the datapipeline repo.
2. **API contract & integration tests** — validate VLink/Vusion HTTP responses, store/product/label snapshots, and database connectivity. These test external system behavior and cross-service flows — they don't belong to any single repo.

Phase 2 introduced the CDC pipeline spanning multiple repos:

```
Vusion/VLink APIs → datapipeline → PostgreSQL (outbox) → event-publisher → Solace
```

True end-to-end validation requires orchestrating components from 4+ repos (datapipeline, event-publisher, database, esl-go-commons). Embedding this in datapipeline creates artificial ownership boundaries and makes the test suite fragile to changes in any single repo.

### Goals

- Test the full ESL platform flow end-to-end, not individual components
- Provide a single place for cross-service integration tests
- Decouple e2e test cadence from individual repo release cycles
- Enable testing against deployed environments (dev, staging)
- Reuse the existing godog BDD framework and step definitions

### Non-goals

- Replace unit or component-level integration tests (those stay in each repo)
- Test infrastructure/K8s concerns (that's helm chart territory)
- Provide a general-purpose test framework for other teams

## Repositories Reference

| Component | Repo | Role in E2E |
|-----------|------|-------------|
| esl-go-commons | `sonaemc-instore/esl-go-commons` | Shared types (entity, event, outbox) — not tested directly, but used by test code |
| database | `sonaemc-instore/esl-database` | Flyway migrations — e2e needs a migrated PostgreSQL |
| datapipeline | `sonaemc-instore/datapipeline` | Syncs APIs → PostgreSQL + outbox. CLI tests stay here |
| event-publisher | `sonaemc-instore/event-publisher` | Polls outbox → publishes to Solace |
| go-solace-sdk | `sonaemc-instore/go-solace-sdk` | Solace client — used by event-publisher, not tested directly |
| k8s helm | `sonaemc-instore/esl-k8s` | Deployment charts — out of scope |

## What Moves vs What Stays

### Stays in datapipeline

- `godog-e2e/bdd/cli_steps.go` and CLI feature files (`cli_initialization.feature`, `config_validate*.feature`, `run_*.feature`, `version.feature`) — these test the datapipeline binary directly
- All `*_integration_test.go` files — component-level tests with testcontainers
- The `//go:build e2e` tag on `suite_test.go` remains to deactivate them

### Moves to esl-e2e

- API contract tests (VLink/Vusion product, label, store features)
- Snapshot infrastructure and fixtures
- Database connectivity validation
- The reusable framework: `domain/api.go`, `helpers/`, `snapshot/`

### New in esl-e2e

- Full pipeline flow tests (API → datapipeline → outbox → event-publisher → Solace)
- Docker-compose orchestrating all services together
- Environment profiles for local vs deployed testing

## Repository Structure

```
esl-e2e/
├── bdd/
│   ├── suite.go              # TestSuite + Scenario initializers
│   ├── suite_test.go         # TestMain entry point
│   ├── api_steps.go          # HTTP API steps (extracted from datapipeline)
│   ├── db_steps.go           # Database assertion steps
│   ├── solace_steps.go       # NEW: Solace message consumption/assertion steps
│   ├── pipeline_steps.go     # NEW: Orchestrates datapipeline execution + waits
│   └── file_steps.go         # Temp file management
├── domain/
│   ├── api.go                # HTTP client context (extracted)
│   ├── db.go                 # PostgreSQL context (extracted)
│   └── solace.go             # NEW: Solace consumer context
├── features/
│   ├── contracts/            # API contract tests (moved from datapipeline)
│   │   ├── vlink_products.feature
│   │   ├── vlink_labels.feature
│   │   ├── vusion_stores.feature
│   │   └── vusion_store_search.feature
│   └── flows/                # NEW: Cross-service flow tests
│       ├── sync_creates_outbox_events.feature
│       ├── outbox_events_published_to_solace.feature
│       └── full_pipeline.feature
├── fixtures/                 # Response snapshots (moved from datapipeline)
├── helpers/                  # JSON matching, fixture management (extracted)
├── snapshot/                 # Snapshot registry + normalizers (extracted)
├── types/                    # API response types (extracted)
├── docker-compose.yml        # PostgreSQL + datapipeline + event-publisher + Solace
├── .env.example              # Environment template
├── .env.local                # (gitignored) Local overrides
├── Makefile
├── go.mod
└── README.md
```

## Test Categories

### 1. API Contract Tests (migrated)

Validate that VLink/Vusion APIs return expected shapes. These are the existing godog scenarios — moved as-is with their snapshots and normalizers.

**Tags:** `@contract`, `@vlink`, `@vusion`

**Environment:** needs real API keys (`.env`), no local services required.

```gherkin
@contract @vlink
Feature: VLink Products API
  Background: Set variables
    Given I set vars:
      | store_id | 009648 |
    And I set headers:
      | Ocp-Apim-Subscription-Key | $VLINK_PRO_SUBSCRIPTION_KEY |
  ...
```

### 2. Pipeline Flow Tests (new)

Validate the end-to-end data flow: API → datapipeline → PostgreSQL outbox → event-publisher → Solace.

**Tags:** `@flow`, `@pipeline`

**Environment:** all services running via docker-compose or deployed environment.

```gherkin
@flow @pipeline
Feature: Sync creates outbox events
  Background:
    Given a migrated PostgreSQL database
    And the datapipeline is configured for store "009648"

  Scenario: New store sync produces CREATED events in outbox
    When the datapipeline runs a sync for store "009648"
    Then the outbox should contain events with type "CREATED"
    And the entity type should be "store"

  Scenario: Re-sync unchanged store produces no outbox events
    Given store "009648" was previously synced
    When the datapipeline runs a sync for store "009648"
    Then the outbox should contain 0 new events
```

```gherkin
@flow @solace
Feature: Outbox events published to Solace
  Background:
    Given a migrated PostgreSQL database
    And a Solace broker is available
    And the event-publisher is running

  Scenario: CREATED outbox event is published to Solace
    Given the outbox contains a CREATED event for entity "store" with key:
      | retail_chain_id | RC1  |
      | store_id        | S001 |
    When the event-publisher polls the outbox
    Then a message should appear on topic "esl/events/store"
    And the message payload should contain:
      | event_type  | CREATED |
      | entity_type | store   |
    And the outbox event status should be "DELIVERED"
```

### 3. Full End-to-End (new, future)

Combines contract + pipeline + publisher in a single flow. Most valuable but requires all services.

**Tags:** `@e2e`

```gherkin
@e2e
Feature: Full pipeline — API to Solace
  Scenario: Store data flows from Vusion API to Solace topic
    Given the platform is running for store "009648"
    When the datapipeline syncs store "009648"
    Then store data should be written to PostgreSQL
    And outbox events should be created
    And messages should appear on Solace topic "esl/events/store"
```

## Docker-Compose

For local execution, the e2e repo provides a docker-compose that spins up the full platform:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    ports: ["55432:5432"]
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]

  flyway:
    image: flyway/flyway
    depends_on:
      postgres: { condition: service_healthy }
    volumes:
      - ./migrations:/flyway/sql    # copied or mounted from esl-database
    command: migrate

  # datapipeline and event-publisher can run as:
  # Option A: Pre-built Docker images (CI, deployed testing)
  # Option B: `go run` from local checkout (development)
```

**Decision: how to run datapipeline + event-publisher in e2e**

| Option | Pros | Cons |
|--------|------|------|
| Docker images from CI | Reproducible, tests what ships | Requires image registry, slower iteration |
| `go run` from local checkouts | Fast feedback during dev | Requires all repos checked out, not reproducible |
| Docker images built locally | Middle ground | Slow build, manual step |

**Recommendation:** support both. Default to Docker images (CI), with a `LOCAL_REPOS` env var override for development that points to local checkouts. The Makefile provides targets for both modes.

## Environment Configuration

```bash
# .env.example

# --- API Contract Tests ---
API_BASE_VUSION=https://...
API_BASE_VLINK=https://...
VUSION_PRO_SUBSCRIPTION_KEY=...
VLINK_PRO_SUBSCRIPTION_KEY=...

# --- Database ---
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=55432
POSTGRES_USER=testuser
POSTGRES_PASSWORD=testpass
POSTGRES_DB=testdb

# --- Solace (flow tests) ---
SOLACE_HOST=localhost
SOLACE_PORT=55555
SOLACE_VPN=default
SOLACE_USERNAME=...
SOLACE_PASSWORD=...

# --- Services (flow tests) ---
# Option A: Docker images
DATAPIPELINE_IMAGE=eslorchestrator:latest
EVENT_PUBLISHER_IMAGE=event-publisher:latest
# Option B: Local repos
# LOCAL_REPOS=/Users/.../sonae/esl

# --- Debug ---
HTTP_DEBUG=false
```

## Makefile Targets

```makefile
## test-contracts: Run API contract tests only
test-contracts:
	$(GOTEST) -v ./bdd -args -godog.tags=@contract

## test-flows: Run pipeline flow tests (requires docker-compose up)
test-flows:
	$(GOTEST) -v ./bdd -args -godog.tags=@flow

## test-e2e: Run full end-to-end tests
test-e2e:
	$(GOTEST) -v ./bdd -args -godog.tags=@e2e

## test-all: Run all tests
test-all:
	$(GOTEST) -v ./bdd

## up: Start all services via docker-compose
up:
	docker compose up -d --wait

## down: Stop all services
down:
	docker compose down -v

## snapshot-update: Re-capture API response snapshots
snapshot-update:
	GODOG_SNAPSHOT_UPDATE=true $(GOTEST) -v ./bdd -args -godog.tags=@contract
```

## Migration Steps

### Phase 1: Create repo, migrate contract tests

1. Create `esl-e2e` repo in `sonaemc-instore` org
2. Initialize Go module (`go mod init github.com/sonaemc-instore/esl-e2e`)
3. Copy reusable framework from datapipeline's `godog-e2e/`:
   - `domain/api.go`, `domain/db.go`
   - `helpers/steps_helpers.go`
   - `snapshot/` (registry, normalizers, assertions)
   - `types/` (API response structs)
   - `bdd/api_steps.go`, `bdd/db_steps.go`, `bdd/file_steps.go`
   - `bdd/suite.go` (adapted — remove CLI initializer)
   - `fixtures/` (snapshot JSON files)
4. Move API contract feature files (`vlink_*.feature`, `vusion_*.feature`)
5. Adapt `suite_test.go` — no CLI context, no `go run` dependency
6. Add `.env.example`, `docker-compose.yml` (PostgreSQL only for now), `Makefile`
7. Verify `make test-contracts` passes against real APIs
8. Remove migrated API features + dead code from datapipeline's `godog-e2e/`

### Phase 2: Add pipeline flow tests

9. Add `pipeline_steps.go` — steps to run datapipeline (via Docker image or local binary)
10. Add `solace_steps.go` + `domain/solace.go` — Solace consumer context for assertions
11. Write `sync_creates_outbox_events.feature`
12. Write `outbox_events_published_to_solace.feature`
13. Expand docker-compose with Flyway + service containers
14. Verify `make test-flows` passes locally

### Phase 3: Full e2e + CI

15. Write `full_pipeline.feature` combining all stages
16. Add CI workflow (GitHub Actions) triggered on:
    - Push to esl-e2e main
    - Dispatch from datapipeline / event-publisher CI (on release)
    - Scheduled nightly against staging
17. Document in esl-documentation

## Open Questions

- **Solace broker for local testing:** Use a local Solace PubSub+ container (available as Docker image) or mock? Real container is more faithful but heavier.
- **Database migrations source:** Copy migration SQL files into esl-e2e, or pull from esl-database at test time? Copying is simpler but creates drift risk.
- **CI trigger strategy:** Should datapipeline/event-publisher CI trigger esl-e2e on every PR, or only on release?
- **Snapshot update workflow:** When APIs change, who updates fixtures — the team that changed the API, or the e2e repo maintainer?
