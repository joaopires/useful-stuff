# Database

## Overview

Phase 2 adds a single new table — `event_outbox` — to the existing `esl` schema. This table implements the transactional outbox pattern: the Data Pipeline inserts change events into the outbox within the same database transaction as entity upserts, and the Event Publisher polls the outbox to deliver events to Solace.

All existing Phase 1 tables remain unchanged.

![ER Diagram](diagrams/er-diagram.png)

## Event Outbox Table

### event_outbox

Stores CDC events detected during pipeline execution. Each row represents a single CREATED, UPDATED, or DELETED event for one entity record.

| Column | Type | Default | Description |
|---|---|---|---|
| `id` | UUID | `gen_random_uuid()` | Unique event identifier (PK) |
| `event_type` | VARCHAR(20) | — | Change type: `CREATED`, `UPDATED`, or `DELETED` |
| `entity_type` | VARCHAR(50) | — | Entity that changed: `store`, `product`, `label`, `accesspoint` |
| `entity_key` | JSONB | — | Composite business key identifying the record (e.g., `{"retail_chain_id": "RC001", "store_id": "S001"}`) |
| `payload` | JSONB | — | Event payload — full snapshot for CREATED, changed-field diffs for UPDATED, empty `{}` for DELETED |
| `occurred_at` | TIMESTAMPTZ | `NOW()` | When the change was detected (defaults to transaction time) |
| `status` | TEXT | `'PENDING'` | Delivery status: `PENDING`, `DELIVERED`, or `FAILED` |
| `delivered_at` | TIMESTAMPTZ | `NULL` | When the event was published to Solace |

**Primary key:** `id` (UUID, database-generated)

**Constraint:** `CHECK (status IN ('PENDING', 'DELIVERED', 'FAILED'))`

The `id` column uses UUIDs rather than sequential integers. This enables deterministic event identifiers that can be included in published messages for downstream deduplication — consumers receiving the same event twice (at-least-once delivery) can use the UUID to discard duplicates.

The `status` column tracks delivery lifecycle explicitly. The Event Publisher transitions events from `PENDING` to `DELIVERED` (with `delivered_at` timestamp) after successful publication, or to `FAILED` for permanent errors. This explicit status model enables straightforward observability — a simple `GROUP BY status` reveals the outbox health at a glance.

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

**UPDATED events** carry only the changed fields, with old and new values:

```json
{
  "event_type": "UPDATED",
  "entity_type": "product",
  "entity_key": {"retail_chain_id": "RC001", "store_id": "S001", "item_id": "P001"},
  "payload": {
    "price": {"old": 1.29, "new": 1.49},
    "status": {"old": "active", "new": "updated"}
  }
}
```

**DELETED events** carry an empty payload — the entity key identifies the deleted record, and the Event Publisher adds `eventId` and `send_date` at publish time:

```json
{
  "event_type": "DELETED",
  "entity_type": "product",
  "entity_key": {"retail_chain_id": "RC001", "store_id": "S001", "item_id": "P001"},
  "payload": {}
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
    ON esl.event_outbox (occurred_at) WHERE status = 'PENDING';

CREATE INDEX idx_event_outbox_delivered
    ON esl.event_outbox (delivered_at) WHERE status = 'DELIVERED';
```

| Index | Purpose |
|---|---|
| `idx_event_outbox_pending` | Event Publisher queries: `SELECT ... WHERE status = 'PENDING' ORDER BY occurred_at` |
| `idx_event_outbox_delivered` | Retention cleanup: `DELETE ... WHERE status = 'DELIVERED' AND delivered_at < threshold` |

Partial indexes keep each index small — the pending index only covers rows awaiting delivery, and the delivered index only covers published rows. As events transition from `PENDING` to `DELIVERED`, they move from one index to the other.

## Retention

A stored function handles cleanup of delivered events:

```sql
CREATE OR REPLACE FUNCTION esl.cleanup_delivered_events(retention_days INT DEFAULT 7)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE deleted BIGINT;
BEGIN
    DELETE FROM esl.event_outbox
    WHERE status = 'DELIVERED'
      AND delivered_at < NOW() - (retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS deleted = ROW_COUNT;
    RETURN deleted;
END; $$;
```

The function deletes outbox rows with status `DELIVERED` that were published more than `retention_days` ago (default: 7 days) and returns the number of deleted rows. It is designed to be called externally — by `pg_cron`, the Event Publisher, or an application-level scheduler.

Only delivered events are eligible for cleanup. Events with status `PENDING` or `FAILED` are never deleted, regardless of age, to prevent data loss.

## Migrations

| Version | Description |
|---|---|
| V1.0.0.15 | Create `event_outbox` table |
| V1.0.0.16 | Create partial indexes on `event_outbox` |
| V1.0.0.17 | Create `cleanup_delivered_events` retention function |
| V1.0.0.18 | Create `event_outbox` UUID primary key and retention function |
| V1.0.0.19 | Add `deletion_date` to labels; add `deleted_at` to products and labels |
| V1.0.0.20 | Increase entity ID columns (`item_id`, `label_id`, `access_points.id`) to VARCHAR(255) |

These migrations follow the same conventions established in Phase 1: table and indexes in separate files, snake_case naming, all objects in the `esl` schema.

### Deletion columns (V1.0.0.19)

Products and labels support soft-delete via dual timestamps:

| Column | Table | Description |
|---|---|---|
| `deletion_date` | products, labels | Business timestamp from Vusion — when the record was marked deleted. Reliably populated for products; may be NULL for labels (Vusion returns NULL even on confirmed-DELETED label rows) |
| `deleted_at` | products, labels | Audit timestamp — when the pipeline first detected the deletion. Set by `injectAuditTimestamps` on records with `status = 'DELETED'`; preserved on subsequent upserts via `COALESCE` |

Stores and access points have no deletion lifecycle in Vusion and do not have these columns.

## Key Design Decisions

### Single outbox table for all entity types

All entity types share one `event_outbox` table rather than having per-entity outbox tables. The `entity_type` column distinguishes between them. This simplifies the Event Publisher (one polling query), keeps migration count low, and avoids schema proliferation as new entity types are added.

### JSONB for entity_key and payload

Both `entity_key` and `payload` use JSONB rather than typed columns. This accommodates the varying composite key structures across entity types (2-column key for stores, 3-column key for products) and the variable shape of diff payloads without requiring schema changes.

### UUID primary key over sequential integer

A UUID primary key (`gen_random_uuid()`) was chosen over `BIGSERIAL` to provide deterministic event identifiers. The UUID is included in the published Solace message, enabling downstream consumers to deduplicate events under at-least-once delivery semantics — if the Event Publisher crashes after publishing but before marking the row as `DELIVERED`, the same event may be published again on restart, and consumers can detect the duplicate by its UUID.

### Explicit status column over NULL-based tracking

An explicit `status` column (`PENDING` → `DELIVERED` / `FAILED`) was chosen over using `delivered_at IS NULL` as the delivery indicator. The explicit model provides clearer semantics, enables a `FAILED` state for permanent errors, and simplifies observability — `SELECT status, COUNT(*) FROM event_outbox GROUP BY status` gives a complete health snapshot.

### Partial indexes over full indexes

Full indexes on `occurred_at` or `delivered_at` would include all rows. Partial indexes are more efficient because the outbox has a natural lifecycle: rows start as `PENDING` (matched by the pending index) and transition to `DELIVERED` (matched by the delivered index), then are eventually deleted by the retention function.

### Retention via function, not trigger

Unlike Phase 1's `sync_state` tables which use `AFTER INSERT` triggers for retention, the outbox uses an explicitly called function. This avoids adding cleanup overhead to every pipeline transaction — retention runs on its own schedule, independent of the write path.
