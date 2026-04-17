# Event Publisher — Parallel Publishing (DRAFT plan)

**Status:** DRAFT. Not committed. Execute only when a trigger condition is met (see below).

**Origin:** Drafted 2026-04-17 during the active/passive analysis (see `esl-documentation/plans/active-passive/00-overview.md` § Scaling context). Captured here so a future engineer (or a future Claude session) can resume cold without re-doing the analysis.

**Scope boundary:** This plan is orthogonal to the datapipeline active/passive decision. Whichever active/passive option is chosen, this throughput plan stands on its own.

## Trigger conditions

Start executing this plan when any of the following becomes true:

1. A **300-store rollout date** is announced by the client (currently unknown as of 2026-04-17) — lead time of at least 4 weeks before the flip.
2. **Measured pilot metrics** show publisher saturation: daily delta drain time > 10 min, or any initial-sync drain > 1 hour.
3. The ops team raises concerns about outbox or Solace backpressure in pilot operation.

Until one of these fires, the current sequential publisher handles pilot volumes (4 stores) comfortably and no code change is required.

## Goal

Raise `event-publisher` sustained publish throughput from ~100 events/sec (current sequential) to **~2,000–5,000 events/sec** while preserving per-entity event ordering, sized to handle the 300-store flip:

- 7.5M products + 7.5M labels × 1 CREATED event each ≈ **~15M outbox rows** during the initial CDC sync.
- Daily delta at 1–5% change rate: **~150k–750k events/day**.
- Target drain windows: initial spike < 1 hour; daily delta < 5 min.

See `project_production_scale.md` for the canonical scale figures.

## Prerequisites (resolve before kicking off)

| # | Question | Who answers | Why it matters |
|---|----|----|----|
| 1 | What is the consumer ordering contract on Solace? Strict per-entity, or timestamp-idempotent (consumers rely on `occurred_at`)? | Product/architecture | Decides whether Solace ordering keys are required and whether partitioned leases are a hard requirement at scale. |
| 2 | Solace broker throughput headroom — can it sustain ~5k guaranteed publishes/sec on the `in-store/orchestratoresl/*` topics? | Ops / Solace admin | Sets the upper bound on in-pod parallelism before multi-pod is required. |
| 3 | Postgres WAL and autovacuum headroom — can it sustain ~4k outbox inserts/sec for 1 hour? | DBA / ops | Datapipeline insert rate during initial flip. |
| 4 | Outbox retention policy under 15M-row bursts (current default 7 days → ~105M rows retained at peak). Should retention shorten, or should the table be partitioned? | DBA / ops | Maintenance window and query performance on `event_outbox`. |
| 5 | Do we still want a single-lease `event-publisher` (Option 2/3 carryover), or is no-lease multi-replica with SKIP LOCKED acceptable given answer (1)? | Architecture | Anchors the whole plan — Phase A lives inside a single active pod; Phase B assumes partitioned leases. |

## Design

### Phase A — In-pod parallel publishing with ordering preservation

Replace the sequential `for` loop in `event-publisher/internal/relay/relay.go` (currently lines ~152–177) with a bounded worker pool that publishes in parallel but records results in **fetch order** so the subsequent `MarkDelivered` / `MarkFailed` UPDATEs reflect that ordering.

**Pseudo-code sketch:**

```go
// Inside Relay.poll, after FetchPending returns `rows` ordered by occurred_at:
results := make([]publishResult, len(rows))

sem := make(chan struct{}, r.cfg.WorkerCount) // e.g. 20
var wg sync.WaitGroup

for i, row := range rows {
    wg.Add(1)
    sem <- struct{}{}
    go func(idx int, row outbox.Row) {
        defer wg.Done()
        defer func() { <-sem }()

        pub, terr := transform.ToPublishedEvent(row.ChangeEvent, row.ID, r.cfg.TopicPrefix, now)
        if terr != nil {
            results[idx] = publishResult{row: row, err: terr, kind: transformErr}
            return
        }

        perr := r.publisher.Publish(ctx, pub.Topic, pub.Payload)
        results[idx] = publishResult{row: row, err: perr, kind: publishErr}
    }(i, row)
}
wg.Wait()

// Walk results IN FETCH ORDER (indexed by i) to accumulate deliveredIDs / failedIDs.
// Per-batch ordering guaranteed because the `results` slice is written by index and
// read sequentially after wg.Wait().
for _, res := range results {
    if res.err == nil {
        deliveredIDs = append(deliveredIDs, res.row.ID)
    } else {
        failedIDs = append(failedIDs, res.row.ID)
    }
}

// MarkDelivered / MarkFailed, then Commit — same as today.
```

**Ordering caveats to resolve during implementation (ties to prerequisite #1):**

- **Within a batch:** results are indexed by fetch position, so the DB commit reflects fetch order even though publishes happened concurrently.
- **On Solace:** concurrent publishes to the same topic land at the broker in whatever order acks complete. If consumers rely on strict per-entity ordering, **use Solace ordering keys**: include `entity_key` (or its hash) as the message's `ApplicationMessageId` / delivery group ID so Solace serialises delivery for the same key. Verify the exact Solace API with the SDK team.
- **Alternative if ordering keys are unavailable:** serialise same-entity events inside the batch (hash-sharded worker pool). Given the CDC invariant (one event per entity per sync), within-batch same-entity collisions are rare; a simple hash-to-worker dispatch preserves per-key ordering at minor throughput cost.

### Phase B — Partitioned leases (multi-pod horizontal scaling)

Only if Phase A exhausted and the prerequisite-1 answer demands strict ordering with more throughput than a single parallelised pod delivers.

**Schema changes:**

```sql
-- New migration V1.0.0.NN__partition_event_outbox.sql
ALTER TABLE esl.event_outbox ADD COLUMN partition_key INT NOT NULL DEFAULT 0;
CREATE INDEX idx_event_outbox_partition_status
    ON esl.event_outbox (partition_key, status, occurred_at);

-- Backfill for existing rows:
-- UPDATE esl.event_outbox SET partition_key = abs(hashtext(entity_key::text)) % :N;
```

- `partition_key` is computed at outbox-insert time in datapipeline (simple hash of entity_key serialised as JSON, modulo N).
- `N` is operational config, starts at e.g. 4.

**Lease library extension:**

- Lease `name` extended to `(name, partition_index)` — i.e., N lease rows named `event-publisher/0`, `event-publisher/1`, ..., `event-publisher/N-1`.
- On startup, each pod iterates partition slots and attempts acquire. First free one wins.
- Graceful shutdown releases only the slot that pod owns.
- Passive watcher polls all slots; if any slot expires, attempts to acquire it.

**Fetch query extension:**

```sql
SELECT id, event_type, entity_type, entity_key, payload, status, occurred_at, delivered_at
FROM event_outbox
WHERE status = $1 AND partition_key = $2
ORDER BY occurred_at
LIMIT $3
FOR UPDATE SKIP LOCKED
```

**Per-entity ordering is preserved across pods** because the same `entity_key` always hashes to the same partition, and only one pod owns that partition at any time.

### Pre-flip ops sizing checks (pair with prerequisites #2–#4)

- Solace: sustained guaranteed-publish throughput test at target rate (e.g., 5k/sec) against dev broker. Confirm connection/session limits.
- Postgres: stress-test outbox insert rate during a simulated initial sync. Confirm autovacuum keeps up with the churn as `MarkDelivered` immediately supersedes recent inserts.
- Outbox retention: decide between shorter retention (e.g. 2 days) + monitoring, or hash partitioning of `event_outbox` by `occurred_at` date.

### Config additions

In `event-publisher/config.yaml` → `publisher` block:

```yaml
publisher:
  poll_interval: 1s
  batch_size: 100             # existing
  shutdown_timeout: 30s       # existing
  worker_count: 1             # NEW — 1 = current sequential behavior; bump for Phase A
  # Phase B only (ignore when building Phase A):
  partition_index: 0          # NEW — which partition slot this pod owns
  partition_count: 1          # NEW — total number of partitions (must match outbox partition_key values)
```

Starting `worker_count: 1` as the default keeps behaviour unchanged on rollout. Operators bump per env.

## Rollout sequence

1. **Prerequisites #1–#5 answered.**
2. **Lease library for datapipeline is in place** (presumed from whichever active/passive path was chosen — options 2 or 3). If option 1 was chosen, a minimal lease for the publisher still needs to be built; this plan assumes the lease primitive exists.
3. **Phase A implementation:**
   - Add `worker_count` config.
   - Replace sequential loop with bounded worker pool.
   - Ordering key added to Solace publishes (if prerequisite #1 demands per-entity).
   - Unit + integration tests with testcontainers and a fake Solace publisher; include a test that verifies within-batch commit order.
   - Ship to PP with `worker_count: 1` (behavior unchanged).
4. **PP validation:**
   - Ramp `worker_count: 1 → 5 → 20`. Measure publish latency, drain time, DB contention.
   - Run a synthetic initial-sync load (e.g. a test-only migration seeding 1M rows). Confirm drain time scales as expected.
5. **Production rollout** with observation windows.
6. **Phase B (only if triggered):**
   - Ops migration to add `partition_key` column with backfill.
   - Datapipeline insert path sets `partition_key` on outbox rows.
   - Lease library extension for partition slots.
   - Config + Helm additions for `partition_index` and `partition_count`.
   - Scale event-publisher Deployment to N replicas.
   - Validate N-pod operation in PP before prd.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Ordering regression on Solace under concurrent publish | Medium | Ordering keys (Solace ApplicationMessageId / partition key) or hash-sharded worker pool. Gate on prerequisite #1. |
| At-least-once duplicate on pod crash mid-batch (existing behaviour, now faster to surface) | Low | Idempotent consumers remain a requirement. |
| Worker pool deadlock (all workers blocked on Solace) | Low | Bounded semaphore; publish-level timeout (already in Solace client). |
| Config default `worker_count: 1` forgotten → no behaviour change deployed | Low | PR template checklist; explicit PP ramp step in runbook. |
| Partitioned lease re-balancing during rolling restart | Medium (Phase B only) | Graceful lease release on SIGTERM; passive watcher picks up released slot within seconds. |
| `partition_key` backfill UPDATE takes a long lock on `event_outbox` | Medium (Phase B only) | Run backfill in batches with limit + commit pattern. Maintenance window advisable. |

## Out of scope

- Replacing Solace with a different broker.
- Reshaping the outbox polling model (e.g. LISTEN/NOTIFY or logical replication) — already declined in the Phase 2 masterplan.
- Changing datapipeline's CDC classification logic.

## Open questions tracked for activation day

- Ordering contract (prerequisite #1).
- 300-store rollout date.
- Measured pilot publish-latency baseline (add OTel histogram `event_publisher.publish_latency_seconds` before activation; currently not present).
- Whether the same partitioned-lease approach should be retrofitted to datapipeline for parallel sink writes at prod scale — separate analysis.

## Relationship to other plans

- Depends on the lease primitive built for whichever **active/passive** option is picked (see `esl-documentation/plans/active-passive/`).
- Does **not** block Phase 2 rollout at pilot scale.
- Must land **before** the 300-store flip.

## Sign-off when activated

Edit this section on activation day:

- Activation date: _tbd_
- Trigger condition met: _tbd_
- Plan owner: _tbd_
- Target completion: _tbd_
