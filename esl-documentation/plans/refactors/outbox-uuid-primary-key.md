# Refactor: Outbox UUID Primary Key

**Scope:** database, datapipeline, event-publisher
**Depends on:** event-publisher implementation (step 6 complete)

## Motivation

The event-publisher guarantees at-least-once delivery. In crash scenarios (process dies mid-batch, between publishing to Solace and committing to PostgreSQL), events may be re-published on recovery. For consumers to deduplicate, the published `eventId` must be **deterministic** — the same outbox row must always produce the same `eventId`.

Currently `eventId` is a UUID v4 generated at transform time. On re-publish, a new UUID is generated, making deduplication impossible. The fix: use the outbox table's primary key as the `eventId`. The client requires `eventId` to be a UUID, so the outbox `id` column must change from `BIGSERIAL` to `UUID`.

## Changes

### 1. database — modify existing migration (not yet deployed)

Change the `CREATE TABLE` in `V1.0.0.15__create_event_outbox.sql` directly:

```sql
CREATE TABLE esl.event_outbox (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      VARCHAR(20)  NOT NULL,
    entity_type     VARCHAR(50)  NOT NULL,
    entity_key      JSONB        NOT NULL,
    payload         JSONB        NOT NULL,
    status          VARCHAR(10)  NOT NULL DEFAULT 'PENDING',
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ
);
```

No index changes needed — they reference `occurred_at` and `delivered_at`, not `id`.

### 2. datapipeline — update outbox INSERT

Verify that:
- It does **not** specify the `id` column in INSERT (relies on DEFAULT) — if so, no change needed
- If it reads back the `id` after insert, update the type from `int64` to `string`

### 3. event-publisher — update model and transform

- `outbox.Row.ID`: change from `int64` to `string` (scanned from UUID column)
- `outbox.Repository`: update scan and query parameter types for `id`
- `transform.ToPublishedEvent`: use `row.ID` as `eventId` instead of `uuid.New().String()`
- Remove `github.com/google/uuid` dependency if no longer used elsewhere
- Update unit tests and integration tests
- Regenerate mocks (Repository interface `ids` param changes from `[]int64` to `[]string`)

## Implementation order

1. database — modify original CREATE TABLE migration
2. datapipeline — verify/update INSERT (if needed)
3. event-publisher — update model, transform, tests
4. Verify: `make lint && go test -tags=integration ./...` in both datapipeline and event-publisher

## Verification

Each repository: `make lint && go test -tags=integration ./...` must pass with 0 issues.
