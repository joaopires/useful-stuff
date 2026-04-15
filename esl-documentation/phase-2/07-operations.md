# Operations & Maintenance

## Overview

Phase 2 operations focus on three areas:

1. **Monitoring** — outbox health, publisher throughput, Solace connectivity
2. **Manual intervention** — recovering from failed or stuck events without data loss
3. **Capacity planning** — when to scale publisher replicas, when to adjust batch or poll settings

## Monitoring

### Outbox health (PostgreSQL)

The `event_outbox` table is the primary observability surface. Status counts give an immediate view of system health:

```sql
SELECT status, COUNT(*)
FROM esl.event_outbox
GROUP BY status;
```

Expected distributions:

| Distribution | Meaning |
|---|---|
| Mostly `DELIVERED`, near-zero `PENDING` | Normal operation — publisher keeps up with producer |
| Growing `PENDING` | Publisher not running, crashed, or unable to reach Solace |
| Growing `FAILED` | Transform or publish errors — see runbook |

Useful supplementary queries:

```sql
-- Age of oldest pending event
SELECT MIN(occurred_at) AS oldest_pending,
       NOW() - MIN(occurred_at) AS age
FROM esl.event_outbox
WHERE status = 'PENDING';

-- Recent failed events
SELECT id, entity_type, event_type, occurred_at
FROM esl.event_outbox
WHERE status = 'FAILED'
ORDER BY occurred_at DESC
LIMIT 20;

-- Table size (for retention monitoring)
SELECT pg_size_pretty(pg_total_relation_size('esl.event_outbox')) AS total_size,
       COUNT(*) AS rows
FROM esl.event_outbox;
```

### Publisher metrics (OpenTelemetry)

The event-publisher exports OTel metrics via the shared collector:

| Metric | Type | Attributes | Investigate when |
|---|---|---|---|
| `event_publisher.events_processed_total` | Counter | `entity_type`, `event_type`, `status` | `status=failed` rate > 0 |
| `event_publisher.poll_batch_size` | Histogram | — | Values consistently at `batch_size` (100) → publisher lagging |
| `event_publisher.poll_cycles_total` | Counter | — | Stops incrementing → publisher deadlocked or crashed |
| `solace.producer.publish_retries` | Counter | — | Rate > 0 → broker latency or connection instability |
| `solace.core.connection_drops` | Counter | — | Any non-zero count → broker-side or network issue |

### Log filtering (Zap)

The event-publisher uses structured JSON logs. All log entries include `event_id`, `entity_type`, and `status` when relevant. Useful queries:

```sh
# All warn/error logs in last hour
kubectl logs -l app=orchestrator-esl-eventpublisher --since=1h | \
  jq -c 'select(.level == "warn" or .level == "error")'

# Trace a specific event end-to-end
kubectl logs -l app=orchestrator-esl-eventpublisher --since=24h | \
  jq -c 'select(.event_id == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")'

# Group publish failures by error message
kubectl logs -l app=orchestrator-esl-eventpublisher --since=24h | \
  jq -r 'select(.msg == "publish failed") | .error' | \
  sort | uniq -c | sort -rn
```

## Runbook

### Publisher pod stuck in CrashLoopBackOff

**Common causes:**

1. ExternalSecret has not reconciled — missing or malformed Vault entries
2. Solace credentials invalid — authentication failure at broker
3. DB credentials invalid — pool fails to initialize

**Diagnosis:**

```sh
kubectl describe pod -l app=orchestrator-esl-eventpublisher | tail -30

# Check ExternalSecret status
kubectl get externalsecret orchestrator-esl-eventpublisher -o yaml | yq '.status'

# Check resulting Secret has all expected keys
kubectl get secret orchestrator-esl-eventpublisher -o json | jq '.data | keys'
```

Expected keys in the resulting Secret:
```
DbHost, DbPort, DbUser, DbPassword, DbName, DbSchema,
SolaceHost, SolaceVpn, SolaceUsername, SolacePassword
```

**Fix:**

- **ExternalSecret `SecretSyncedError`:** verify Vault entries at `{vaultBasePath}/solace` exist and contain `host`, `vpn`, `username`, `password`. After fixing Vault, force a refresh:
  ```sh
  kubectl annotate externalsecret orchestrator-esl-eventpublisher force-sync=$(date +%s) --overwrite
  ```
- **Solace auth fails:** rotate the credential at Solace Cloud, update the corresponding Vault entry.
- **DB auth fails:** same procedure, for `{vaultBasePath}/database`.

### Outbox `PENDING` backlog is growing

**Diagnosis:**

```sh
# Is publisher running?
kubectl get pods -l app=orchestrator-esl-eventpublisher

# Is publisher making poll progress?
kubectl logs -l app=orchestrator-esl-eventpublisher --since=5m --tail=200 | \
  jq -c 'select(.msg | contains("poll cycle"))'

# Is Solace reachable?
kubectl exec -it deploy/orchestrator-esl-eventpublisher -- \
  curl -sf http://localhost:8081/ready
```

**Fix:**

- Publisher not running: address the CrashLoopBackOff case above.
- Publisher running but `/ready` returns 503: the Solace connection dropped. The publisher auto-reconnects per `reconnect_retries` and `reconnect_wait`. If stuck:
  ```sh
  kubectl rollout restart deployment/orchestrator-esl-eventpublisher
  ```

### Outbox `FAILED` events

Every FAILED event has a reason in the publisher's logs. The three categories:

1. **Unsupported entity type** — datapipeline wrote an event type the publisher doesn't know (should never happen after Phase 2 ships; indicates a datapipeline bug)
2. **Missing key fields** — `retail_chain_id` or `store_id` missing from `entity_key`
3. **Publish failure** — Solace unreachable or confirmation timeout exceeded after internal retries

**Recover by resetting to PENDING** after fixing the root cause:

```sql
-- Reset specific failed events (preferred — surgical)
UPDATE esl.event_outbox
SET status = 'PENDING', delivered_at = NULL
WHERE id = ANY('{uuid1,uuid2,uuid3}'::uuid[]);

-- Reset all failed events in a time window
UPDATE esl.event_outbox
SET status = 'PENDING', delivered_at = NULL
WHERE status = 'FAILED'
  AND occurred_at > NOW() - INTERVAL '1 hour';

-- Reset everything FAILED (only if root cause was broker-wide and all should retry)
UPDATE esl.event_outbox
SET status = 'PENDING', delivered_at = NULL
WHERE status = 'FAILED';
```

On the next poll cycle the publisher picks them up.

**Consumer deduplication note:** delivery is at-least-once. Resetting a FAILED event may cause a duplicate publish if the original actually reached Solace but the status update failed. The `eventId` (outbox UUID) stays the same across retries — consumers dedupe by that field.

### Inspect a specific event's contents

```sql
SELECT
  id,
  event_type,
  entity_type,
  entity_key,
  jsonb_pretty(payload) AS payload,
  status,
  occurred_at,
  delivered_at
FROM esl.event_outbox
WHERE id = 'your-uuid-here';
```

### Drain the outbox urgently (emergency only)

If a backlog is safe to discard (e.g., accumulated test data, intentional rollback), mark events as DELIVERED without publishing:

```sql
-- DANGER: these events will NOT be sent to Solace.
-- Use only when the backlog must not be published.
UPDATE esl.event_outbox
SET status = 'DELIVERED', delivered_at = NOW()
WHERE status = 'PENDING'
  AND occurred_at < NOW() - INTERVAL '1 day';
```

Preferred alternative: stop the producer (flip `cdc.enabled: false`), let the publisher drain the queue naturally, then re-enable.

## Scaling

### Publisher replicas

The publisher uses `SELECT ... FOR UPDATE SKIP LOCKED`, so multiple replicas can run concurrently without coordination. Each replica claims distinct rows.

**Single replica (default):**

- Per-entity ordering is preserved — events for the same entity are always delivered in outbox order
- Simpler to monitor (single log stream, single publisher identity in metrics)
- Sufficient for typical ESL workloads (the theoretical ceiling at `pollInterval: 1s, batchSize: 100` is 10,000 events/sec, far above observed rates)

**Multiple replicas:**

- Scales throughput up to the broker's accepted rate
- **Breaks per-entity ordering** — two updates to the same entity may be claimed by different replicas and arrive at Solace out of order
- Required only if single-replica throughput saturates or if high-availability during rolling restart matters
- Increase `replicaCount` in `values-{env}.yaml` under `eventPublisher`

### Batch size and poll interval

| Setting | Default | Increase when | Decrease when |
|---|---|---|---|
| `publisher.batchSize` | 100 | Outbox backlog grows, events produced > consumed | Large batches cause long transaction locks; memory pressure |
| `publisher.pollInterval` | `1s` | Events are sparse, want to reduce DB load | Latency-sensitive delivery needed |

Changes require a Helm values edit and redeploy — no DB migration involved.

### Data pipeline CDC overhead

As documented in [04-datapipeline.md](04-datapipeline.md), CDC adds approximately 30–100% overhead per batch depending on the change ratio. Mitigations if runtime becomes a problem:

1. Profile which entity types drive the most events using the `sink.cdc.events` metric grouped by `event_type`
2. Lower `sink.postgres.batch_size` (currently 500) if per-batch transaction time is too long
3. For one-off heavy loads (full re-sync), temporarily disable CDC (`cdc.enabled: false`), run the sync, then re-enable

## Outbox Retention

Migration V1.0.0.18 (event_outbox_retention) handles periodic cleanup:

- DELIVERED rows older than the retention window (default: 30 days) are purged
- FAILED rows are never purged automatically — manual intervention is required

Monitor table size:

```sql
SELECT pg_size_pretty(pg_total_relation_size('esl.event_outbox')) AS total_size;

-- Count of rows eligible for purge
SELECT COUNT(*)
FROM esl.event_outbox
WHERE status = 'DELIVERED'
  AND delivered_at < NOW() - INTERVAL '30 days';

-- Count of unresolved FAILED rows (investigate if this grows)
SELECT COUNT(*) FROM esl.event_outbox WHERE status = 'FAILED';
```

## Graceful Shutdown

The event-publisher handles SIGTERM cleanly:

1. Kubernetes sends SIGTERM (e.g., during rolling deployment)
2. Publisher stops accepting new poll cycles, finishes any in-flight batch
3. In-flight transaction commits — rows become DELIVERED or FAILED; no rows left in intermediate state
4. Solace client disconnects cleanly
5. Pod exits

If `shutdownTimeout` (default `30s`) is exceeded, Kubernetes sends SIGKILL. Consequences:

- The in-flight transaction rolls back; rows revert to PENDING
- The next pod picks them up on startup
- No data loss (at-least-once)
- Possible duplicate publishes if the pre-rollback batch had partially delivered to Solace (consumers dedupe by `eventId`)

## Disaster Recovery

### Outbox table corrupted or lost

The outbox is not a system of record — entity data in `stores`, `products`, `labels`, `access_points` is. Events can be reconstructed by forcing a full re-sync:

1. Stop the datapipeline CronJob (suspend it)
2. Reset `store_sync_state` to an earlier timestamp to force re-sync of all changed-since data
3. Re-enable the CronJob
4. Next run produces fresh events into the rebuilt outbox
5. Publisher delivers them

Caveat: re-synced events report as UPDATED (not CREATED), because the data is already in place. Consumers that distinguish the two must account for this.

### Solace Cloud extended outage

The publisher marks failed publishes as FAILED. Short outages recover automatically via the publisher's internal retries; longer outages cause the backlog to grow.

For prolonged outages (hours), monitor:

- `event_outbox` row count and disk usage
- `/ready` endpoint status on the publisher pods

When Solace recovers, reset FAILED events to PENDING (see runbook) and allow the publisher to drain the backlog.

### Publisher unable to keep up

If the publisher consistently cannot drain the outbox (publish rate < produce rate):

1. Scale `replicaCount` up (accepting the loss of per-entity ordering)
2. Investigate Solace broker-side limits (queue depth, publish rate throttles)
3. Consider partitioning the outbox by entity_type at the consumer side (out of scope for Phase 2, revisit in Phase 3)
