# Active/Passive Orchestration — Deployment + Internal Scheduler + DB Lease (Option 3, DRAFT)

**Status:** DRAFT. Not committed. Execute only when the trigger conditions below are met. The client chose **Option 1** (config-driven `suspend`) for now — see `plans/active-passive/config-driven.md`. Option 3 is planned as a future release once operational experience with Option 1 justifies the additional complexity.

**Origin:** Drafted 2026-04-17 alongside the Option 1 plan, so a future engineer (or Claude session) can resume cold.

## Trigger conditions

Kick off this plan when any of the following becomes true:

1. **Ops burden from Option 1 is measurable** — e.g., multiple incidents where a missed failover (operator didn't flip `activeCluster` in time) caused a lost daily sync or breached an SLA.
2. **Business requires unattended failover** — on-call rotation can no longer guarantee a human editing a values file within the SLA window (e.g., weekend outages become intolerable).
3. **Phase 2 event-publisher is in production** and the team wants architectural symmetry — both stateful writers as Deployments with the same lease primitive.
4. **Mid-run failure frequency observed >N/year** — empirical signal from `esl.sync_state` that partial runs are costing more than automatic recovery would.

Absent any of these, Option 1 is the chosen steady state. Do not activate this plan preemptively.

## Scope

Execute the full design described in `esl-documentation/plans/active-passive/03-deployment-with-scheduler.md`. That report is the canonical specification — this draft does not duplicate it.

High-level workstreams (each ~1 milestone):

1. **Flyway migration** for `esl.leader_lease(lease_name PK, holder_id, acquired_at, expires_at, heartbeat_at)` — same schema already drafted for Option 2 (still useful if Option 2 was never built).
2. **`esl/common/lease` Go library** with `Acquire` + `StartHeartbeat` + passive-watcher + promotion/demotion semantics. Design with `partition_key` slot argument from day one so the event-publisher throughput extension is additive (see `plans/drafts/event-publisher-parallel-publishing.md`).
3. **`datapipeline` entrypoint refactor** from one-shot CronJob-run to long-running Deployment with an in-process cron scheduler (`robfig/cron/v3`) + health endpoints (`/health`, `/ready`).
4. **Helm chart change:** replace `datapipeline-cronjob.yaml` with `datapipeline-deployment.yaml` (or add alongside behind a toggle for rollback safety during migration).
5. **Rollout in PP** with a minimum 1-week soak covering weekday, weekend, and a simulated pod kill.
6. **Remove Option 1's `suspend` mechanism** from the CronJob (since the CronJob no longer exists after cutover) — delete or clean up `dataPipeline.activeCluster` value.
7. **Runbook update:** replace the Option 1 failover runbook with one reflecting automatic failover + operator-observable lease state.
8. **Event-publisher integration:** apply the same lease library to `event-publisher` as a Deployment leader with a hot standby. Sets up for partitioned-lease scaling later.

## Prerequisites (resolve before starting)

1. **Decision on event-publisher scope:** does this plan bundle `event-publisher` integration, or is that a follow-on? Recommendation: bundle, because the primitive is the same.
2. **Capacity:** ~15–20 engineering days + ≥ 1 week of PP soak. Confirm availability before committing.
3. **Operational readiness:** updated runbooks, training for the oncall team on the new pod lifecycle.
4. **Migration strategy:** decide whether Option 1's `activeCluster` mechanism coexists temporarily (belt-and-braces during the first production window with Deployment mode) or is removed in the same release.

## What this draft is NOT

- Not a re-specification of the design — see `03-deployment-with-scheduler.md` in `plans/active-passive/`.
- Not a commitment to execute — activation requires an explicit decision by the team, driven by one of the trigger conditions.
- Not blocking any current work — Option 1 is sufficient for steady state.

## Relationship to other plans

- Supersedes Option 1 (`../active-passive/config-driven.md`) when executed. Option 1 is the interim; Option 3 is the endpoint.
- Depends on the lease primitive; alternatively, lease primitive can be built standalone first (for event-publisher) and reused here.
- Complements `event-publisher-parallel-publishing.md` (both drafts assume the lease library exists).

## Activation checklist

When a trigger condition fires:

- [ ] Document which trigger condition applies, and why.
- [ ] Confirm the prerequisites above are met.
- [ ] Promote this file from `plans/drafts/` to `plans/active-passive/deployment-scheduler.md` and remove the `DRAFT` marker.
- [ ] Expand the workstream list into milestone-sized sub-plans (same pattern as `plans/phase2/cdc-masterplan.md` splitting into per-scope plans).
- [ ] Schedule PP rollout and soak window.
