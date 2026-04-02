# Plan: phase2-cdc-database

**Scope:** `database` project — new Flyway migrations
**Depends on:** Nothing (can run in parallel with shared package)

## Migration: V1.0.0.15__create_event_outbox.sql

```sql
CREATE TABLE esl.event_outbox (
    id              BIGSERIAL    PRIMARY KEY,
    event_type      VARCHAR(20)  NOT NULL,
    entity_type     VARCHAR(50)  NOT NULL,
    entity_key      JSONB        NOT NULL,
    payload         JSONB        NOT NULL,
    status          VARCHAR(10)  NOT NULL DEFAULT 'PENDING',
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ
);
```

## Migration: V1.0.0.16__create_index_event_outbox.sql

```sql
CREATE INDEX idx_event_outbox_pending
    ON esl.event_outbox (occurred_at) WHERE status = 'PENDING';

CREATE INDEX idx_event_outbox_delivered
    ON esl.event_outbox (delivered_at) WHERE status = 'DELIVERED';

CREATE INDEX idx_event_outbox_failed
    ON esl.event_outbox (occurred_at) WHERE status = 'FAILED';
```

## Migration: V1.0.0.17__event_outbox_retention.sql

Cleanup function for delivered events older than N days (default 7):

```sql
CREATE OR REPLACE FUNCTION esl.cleanup_delivered_events(retention_days INT DEFAULT 7)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE deleted BIGINT;
BEGIN
    DELETE FROM esl.event_outbox
    WHERE status IN ('DELIVERED', 'FAILED')
      AND COALESCE(delivered_at, occurred_at) < NOW() - (retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS deleted = ROW_COUNT;
    RETURN deleted;
END; $$;
```

## Verification

- `docker compose up -d` → Flyway runs migrations
- `psql` → verify table, indexes, function exist
