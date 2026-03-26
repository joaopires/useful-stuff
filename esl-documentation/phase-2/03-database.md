# Database

## Overview

Phase 2 adds a single new table — `event_outbox` — to the existing `esl` schema. This table implements the transactional outbox pattern: the Data Pipeline inserts change events into the outbox within the same database transaction as entity upserts, and the Event Publisher polls the outbox to deliver events to Solace.

All existing Phase 1 tables remain unchanged.

## Event Outbox Table

### event_outbox

Stores CDC events detected during pipeline execution. Each row represents a single CREATED or MODIFIED event for one entity record.

| Column | Type | Description |
|---|---|---|
| `id` | BIGSERIAL | Auto-increment identifier (PK) |
| `event_type` | VARCHAR(20) | Change type: `CREATED` or `MODIFIED` |
| `entity_type` | VARCHAR(50) | Entity that changed: `store`, `product`, `label`, `accesspoint` |
| `entity_key` | JSONB | Composite business key identifying the record (e.g., `{"retail_chain_id": "RC001", "store_id": "S001"}`) |
| `payload` | JSONB | Event payload — full snapshot for CREATED, changed-field diffs for MODIFIED |
| `occurred_at` | TIMESTAMPTZ | When the change was detected (defaults to transaction time) |
| `delivered_at` | TIMESTAMPTZ | When the event was published to Solace (`NULL` = pending delivery) |

**Primary key:** `id` (auto-increment)

The `delivered_at` column serves as the delivery status marker. A `NULL` value indicates the event is pending; the Event Publisher sets it to the current timestamp after successful publication to Solace.

### Payload format

**CREATED events** carry a full snapshot of the record:

```json
{
  "event_type": "CREATED",
  "entity_type": "product",
  "entity_key": {"retail_chain_id": "RC001", "store_id": "S001", "item_id": "P001"},
  "payload": {
    "name": "Leite Mimosa 1L",
    "price": 1.29,
    "status": "active",
    ...
  }
}
```

**MODIFIED events** carry only the changed fields, with old and new values:

```json
{
  "event_type": "MODIFIED",
  "entity_type": "product",
  "entity_key": {"retail_chain_id": "RC001", "store_id": "S001", "item_id": "P001"},
  "payload": {
    "price": {"old": 1.29, "new": 1.49},
    "status": {"old": "active", "new": "updated"}
  }
}
```

### Comparison scope

When determining whether a record has changed, the following columns are excluded from comparison:

- **Primary key columns** — they identify the record, not its content
- **Audit columns** — `created_at` and `last_updated_at` are set by the database on every upsert and do not reflect a meaningful data change

The source-provided `modification_date` column *is* included in comparisons, as it reflects when the record was last modified in the Vusion system.

## Indexes

Two partial indexes optimise the outbox's two access patterns:

```sql
CREATE INDEX idx_event_outbox_pending
    ON esl.event_outbox (occurred_at) WHERE delivered_at IS NULL;

CREATE INDEX idx_event_outbox_delivered
    ON esl.event_outbox (delivered_at) WHERE delivered_at IS NOT NULL;
```

| Index | Purpose |
|---|---|
| `idx_event_outbox_pending` | Event Publisher queries: `SELECT ... WHERE delivered_at IS NULL ORDER BY occurred_at` |
| `idx_event_outbox_delivered` | Retention cleanup: `DELETE ... WHERE delivered_at IS NOT NULL AND delivered_at < threshold` |

Partial indexes keep each index small — the pending index only covers undelivered rows, and the delivered index only covers published rows. As events are delivered, they move from one index to the other.

## Retention

A stored function handles cleanup of delivered events:

```sql
CREATE OR REPLACE FUNCTION esl.cleanup_delivered_events(retention_days INT DEFAULT 7)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE deleted BIGINT;
BEGIN
    DELETE FROM esl.event_outbox
    WHERE delivered_at IS NOT NULL
      AND delivered_at < NOW() - (retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS deleted = ROW_COUNT;
    RETURN deleted;
END; $$;
```

The function deletes outbox rows that have been delivered more than `retention_days` ago (default: 7 days) and returns the number of deleted rows. It is designed to be called externally — by `pg_cron`, the Event Publisher, or an application-level scheduler.

Only delivered events are eligible for cleanup. Undelivered events (`delivered_at IS NULL`) are never deleted, regardless of age, to prevent data loss.

## Migrations

| Version | Description |
|---|---|
| V1.0.0.15 | Create `event_outbox` table |
| V1.0.0.16 | Create partial indexes on `event_outbox` |
| V1.0.0.17 | Create `cleanup_delivered_events` retention function |

These migrations follow the same conventions established in Phase 1: table and indexes in separate files, snake_case naming, all objects in the `esl` schema.

## Key Design Decisions

### Single outbox table for all entity types

All entity types share one `event_outbox` table rather than having per-entity outbox tables. The `entity_type` column distinguishes between them. This simplifies the Event Publisher (one polling query), keeps migration count low, and avoids schema proliferation as new entity types are added.

### JSONB for entity_key and payload

Both `entity_key` and `payload` use JSONB rather than typed columns. This accommodates the varying composite key structures across entity types (2-column key for stores, 3-column key for products) and the variable shape of diff payloads without requiring schema changes.

### Partial indexes over full indexes

Full indexes on `occurred_at` or `delivered_at` would include all rows. Partial indexes are more efficient because the outbox has a natural lifecycle: rows start as pending (matched by the pending index) and transition to delivered (matched by the delivered index), then are eventually deleted by the retention function.

### Retention via function, not trigger

Unlike Phase 1's `sync_state` tables which use `AFTER INSERT` triggers for retention, the outbox uses an explicitly called function. This avoids adding cleanup overhead to every pipeline transaction — retention runs on its own schedule, independent of the write path.
