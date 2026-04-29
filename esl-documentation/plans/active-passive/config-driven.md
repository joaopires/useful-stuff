# Active/Passive Orchestration — Config-Driven Suspend (Option 1)

## Context

The ESL Orchestrator is deployed to two production OpenShift clusters (`oshift-prd-mts1` primary and `oshift-prd-rba1` redundant) in an active/active pattern. Both clusters run the same workloads:

- **`datapipeline`** CronJob — fires at the same scheduled time on both clusters, doubling Vusion API quota consumption on every run. **Active today, quota-doubling in production.**
- **`event-publisher`** Deployment (Phase 2) — polls the same `event_outbox` table and publishes to Solace. `FOR UPDATE SKIP LOCKED` makes it safe under active/active; the two pods coordinate on the shared outbox via row locks, so each row is processed by exactly one pod. Stays active/active and is **out of scope** for the active/passive scheme.
- **`datafetch`** REST API — stateless; stays active/active for load distribution. Out of scope.

**Decision (2026-04-17, updated 2026-04-29):** proceed with Option 1 from the comparison reports at `esl-documentation/plans/active-passive/` — render-time suspension driven by a shared `activeCluster` value and the `clusterName` injected via ArgoCD `helmParameters`. Manual failover via a one-line edit to the ESL values file. Scope is **`datapipeline` CronJob only**. The previously planned Phase B (extending the same gating to `event-publisher`) was **descoped on 2026-04-29**: event-publisher is safe under active/active via the outbox row locks, so the additional gating buys nothing and the duplicated DB polling is accepted.

Option 3 (Deployment + internal scheduler + DB lease, with automatic failover) is deferred to a future release — see `plans/drafts/active-passive-deployment-scheduler.md`.

## Goal

Ensure `datapipeline` runs **only on the currently-designated active cluster**. This:

- Halves Vusion API quota consumption (from the datapipeline CronJob).
- Establishes the failover convention (a single `activeCluster` value) that the whole platform will adopt.

## Current status (2026-04-29)

### Datapipeline active/passive

- Steps 1–5 done. Chart changes merged via PR #33 (2026-04-22) in `sonaemc-instore/lac1041-instoreorchestrator_esl`. Follow-up PR #41 (branch `feat/datapipeline-suspend-override`, targets `testing`, open as of 2026-04-24) adds a manual `dataPipeline.suspend` override on top of the cluster check — see Step 3e. Dev and PP rollout verified on 2026-04-24, including a successful failover toggle on PP.
- Step 6 (prd rollout) not yet executed — awaiting ≥ 1 week of PP stability.
- Step 8 partial: a `dataPipeline.suspend` bullet was added to `phase-2/06-deployment.md` Configuration Reference (2026-04-24). The `phase-2/07-operations.md` "Active/Passive Failover" section and the `esl_datapipeline_no_successful_run_36h` alert are still outstanding.

### Event-publisher (descoped 2026-04-29)

The previously planned Phase B (gating `event-publisher` via the same `activeCluster` mechanism with `replicas: 0` on the passive cluster) is no longer planned. Rationale:

- The two pods are already safe under active/active via `SELECT … FOR UPDATE SKIP LOCKED` on `event_outbox` — each row is processed by exactly one pod regardless of which cluster picks it up first. No correctness concern.
- The duplicated DB polling (1 query/sec from each pod) is negligible and accepted.
- Adding the gating would remove the second pod's hot-standby benefit on the active cluster outage path; active/active is genuinely better here.

The throughput / scaling work for event-publisher (in-pod parallel publishing for the 300-store rollout) is tracked separately under `plans/drafts/event-publisher-parallel-publishing.md` and is unaffected by this descope.

### Open prerequisites

- None outstanding. Prd cluster-pair confirmed (2026-04-24): active `oshift-prd-rba1`, passive `oshift-prd-mts1`.

### Next up (pickup point)

1. Finish Step 8: draft the `esl_datapipeline_no_successful_run_36h` Prometheus alert. (The `phase-2/07-operations.md` "Active/Passive Failover" section was added on 2026-04-29.)
2. After ≥ 1 week of PP stability, execute Step 6 — production rollout on `oshift-prd-rba1` / `oshift-prd-mts1`.

## Scope

- **In scope**
  - `datapipeline` CronJob (`esl/k8s/helm/templates/datapipeline-cronjob.yaml`).
  - New top-level shared `activeCluster` value in the ESL chart values files.
  - ArgoCD foundations changes to pass `clusterName` into the ESL chart via `helmParameters` — **DONE** by DevOps.
- **Out of scope**
  - `event-publisher` Deployment — stays active/active via outbox row locks (descoped 2026-04-29; see Current status).
  - `datafetch` REST API — stays active/active.
  - Any DB-backed lease primitive, internal scheduler, or Deployment refactor of datapipeline — that's Option 3.
  - Automatic failover — manual edit of `activeCluster` is the chosen mechanism.

## Prerequisites (resolve before starting Step 3)

1. ~~**Ops confirms `clusterName` values**~~ — **DONE (2026-04-22, prd confirmed 2026-04-24).** Confirmed values: `rba-d1` (dev, single cluster), `oshift-pp-rba1` / `oshift-pp-mts1` (PP), `oshift-prd-rba1` / `oshift-prd-mts1` (prd).
2. ~~**ArgoCD `helmParameters` set up**~~ — **DONE (2026-04-22).** DevOps confirmed `clusterName` is passed via `helm.parameters` in the ArgoCD Application (verified on PP).

## Architecture after implementation

```
[ArgoCD Application per cluster]                               <-- DONE by DevOps
  helm.parameters:
    - name: clusterName
      value: <per-cluster identity>    (e.g. oshift-pp-rba1)
      forceString: true

                    │ each physical Argo renders with its own clusterName
                    ▼
[ESL helm chart]
  values-pp.yaml:
    activeCluster: "oshift-pp-rba1"                            <-- Phase A
    dataPipeline: { schedule: "00 12 * * *", ... }             <-- unchanged

  datapipeline-cronjob.yaml:
    spec:
      suspend: {{ ne .Values.clusterName .Values.activeCluster }}  <-- Phase A
      schedule: {{ $dp.schedule | quote }}

  # eventpublisher-deployment.yaml is intentionally NOT gated by activeCluster.
  # event-publisher stays active/active; the two pods coordinate on the
  # shared event_outbox via SELECT ... FOR UPDATE SKIP LOCKED.

Rendered on oshift-pp-rba1 (active):
  CronJob.suspend = false        -> fires at 12:00

Rendered on oshift-pp-mts1 (passive):
  CronJob.suspend = true         -> scheduled but never fires
```

## Implementation steps

### ~~Step 1 — Verify cluster identities~~ DONE

Confirmed cluster identity strings (2026-04-22):

| Environment | Active (primary) | Passive (redundant) |
|---|---|---|
| dev | `rba-d1` | n/a (single cluster) |
| pp | `oshift-pp-rba1` | `oshift-pp-mts1` |
| prd | `oshift-prd-rba1` | `oshift-prd-mts1` |

### ~~Step 2 — Foundations repo `helmParameters`~~ DONE

DevOps has already added `clusterName` to the ArgoCD Application's `helm.parameters` for each cluster. Verified on PP — the Application spec contains:

```yaml
helm:
  parameters:
    - name: clusterName
      value: oshift-pp-mts1
      forceString: true
```

Each physical Argo instance passes its own cluster identity string.

### ~~Step 3 — ESL chart changes (datapipeline only)~~ DONE

Repo: `sonaemc-instore/lac1041-instoreorchestrator_esl` at `k8s/`.

Merged via PR #33 into `testing` (2026-04-22). Also merged PR #32 (sync main into testing) beforehand to reconcile branch divergence.

**3a. Add top-level `activeCluster` to each env values file:**

`clusters/cluster-preproduction/values-pp.yaml`:

```yaml
activeCluster: "oshift-pp-rba1"
```

`clusters/cluster-dev/values-dev.yaml`:

```yaml
activeCluster: "rba-d1"
```

`clusters/cluster-production/values-prd.yaml` — leave for later (prd cluster names TBD).

**3b. Add `suspend` to the datapipeline CronJob template:**

`helm/templates/datapipeline-cronjob.yaml`, inside the CronJob `spec:` block around line 261:

```yaml
spec:
  suspend: {{ ne .Values.clusterName .Values.activeCluster }}   # NEW
  schedule: {{ $dp.schedule | quote }}
  timeZone: {{ $dp.timeZone | default "UTC" | quote }}
  # ... rest unchanged ...
```

**3c. Update CLAUDE.md guidance** in `esl/k8s/CLAUDE.md` to clarify that the rule against `if .Values.X` conditional guards around whole resources still holds, but render-time boolean / conditional expressions on first-class fields (`suspend`, `replicas`) are acceptable.

**3e. Manual `dataPipeline.suspend` override (PR #41, open 2026-04-24).** Extends the suspend expression with an optional `dataPipeline.suspend` flag:

```yaml
suspend: {{ or $dp.suspend (ne .Values.clusterName .Values.activeCluster) }}
```

Setting `dataPipeline.suspend: true` in any env values file force-suspends the CronJob on top of the cluster check — useful for ad-hoc maintenance pauses on the active cluster without touching `activeCluster`. One-way: `suspend: false` cannot un-suspend a passive cluster. Unset/`false` preserves the original cluster-based behavior.

**3d. Verification:**

- Run `helm lint` against all three env values files as usual (existing CI already does this).
- Run `helm template` locally with `--set clusterName=oshift-pp-rba1` and `--set clusterName=oshift-pp-mts1` to confirm `suspend` flips correctly.
- Open PR to testing branch, let the testing cluster exercise it.

### ~~Step 4 — Dev rollout~~ DONE

Verified on `rba-d1` (2026-04-24): CronJob `suspend: false`, scheduled run fired, `esl.sync_state` row as expected.

After PR merges and is promoted to dev:

1. Confirm Argo applied the manifest on `rba-d1` (only cluster):
   - `kubectl get cronjob -n instore-esl-orchestrator-dev orchestrator-esl-datapipeline -o jsonpath='{.spec.suspend}'` returns `false` (since `clusterName` == `activeCluster`).
2. Observe one scheduled datapipeline run; confirm `esl.sync_state` shows one row.
3. Dev has a single cluster so no failover test is possible here — proceed to PP.

### ~~Step 5 — PP rollout~~ DONE

Verified on PP (2026-04-24): `suspend: false` on `oshift-pp-rba1`, `suspend: true` on `oshift-pp-mts1`, scheduled run fired only on the active cluster, `esl.sync_state` row as expected. Failover toggle exercised successfully (flipped `activeCluster` to `oshift-pp-mts1`, confirmed suspend flipped on both clusters, flipped back).

Promoted once dev runs for at least one full scheduled window without regression.

1. Confirm on `oshift-pp-rba1` (active): CronJob `suspend: false`.
2. Confirm on `oshift-pp-mts1` (passive): CronJob `suspend: true`, no Job created at scheduled time.
3. Observe one scheduled datapipeline run on `oshift-pp-rba1`; confirm `esl.sync_state` shows one row.
4. Exercise a failover: flip `activeCluster` to `oshift-pp-mts1` in `values-pp.yaml`, push, wait for Argo. Verify next-day datapipeline fires on mts1 and is suspended on rba1. Flip back.

Datapipeline schedule in PP: `00 12 * * *` (noon).

### Step 6 — Production rollout — PENDING

After PP stable for ≥ 1 week with at least one successful manually-triggered failover. Prd clusters: active `oshift-prd-rba1`, passive `oshift-prd-mts1`.

- ~~Add `activeCluster` to `values-prd.yaml` with the chosen primary cluster name.~~ Done on PR #41 (`oshift-prd-rba1`).
- Deploy during a low-traffic window (outside 19:00 Lisbon).
- Wait for 19:00. Confirm:
  - Active cluster: `orchestrator-esl-datapipeline-<timestamp>` Job exists and runs.
  - Passive cluster: no Job created (CronJob is suspended).
  - `esl.sync_state`: exactly one row for `esl-orchestrator-prd` with the expected timestamp.
  - Vusion quota usage (ops dashboard) halved relative to prior baseline.

### ~~Step 7 — Extend to event-publisher~~ DESCOPED 2026-04-29

Originally planned as Phase B (conditional `replicas` on `eventpublisher-deployment.yaml` driven by the same `activeCluster` mechanism). Descoped 2026-04-29: event-publisher stays active/active because `SELECT … FOR UPDATE SKIP LOCKED` on `event_outbox` already prevents duplicate publishes, and the active/active hot-standby buys more than the gating would. See Current status above.

### Step 8 — Documentation + observability — PARTIAL

Done:

- `dataPipeline.suspend` bullet added to `esl-documentation/phase-2/06-deployment.md` Configuration Reference (2026-04-24, covers the override added in Step 3e).
- "Active/Passive Failover" section added to `esl-documentation/phase-2/07-operations.md` (2026-04-29, includes topology diagram, mechanism overview, cluster identities, unhealthy-cluster signals, failover procedure, post-failover verification, rollback, and the temporary-mechanism note).

Still outstanding:

- Add Prometheus alert (place in `values-observability.yaml` alongside existing alerts):
  - `esl_datapipeline_no_successful_run_36h` — fires if `esl.sync_state` has no `sync_status = 'SUCCESS'` row for `esl-orchestrator-prd` in the last 36 hours.

## Verification checklist

### Sign off per environment

- [ ] `helm template` renders `suspend: false` on active cluster and `suspend: true` on passive cluster.
- [ ] ArgoCD Application `spec.sources[0].helm.parameters` contains `clusterName` in each cluster.
- [ ] `kubectl get cronjob ... -o jsonpath='{.spec.suspend}'` returns the expected boolean per cluster.
- [ ] One scheduled datapipeline window observed: only the active cluster's Job is created.
- [ ] `esl.sync_state` shows exactly one success row per schedule tick.
- [ ] Failover test executed in PP (flip `activeCluster`, confirm CronJob suspend flips, flip back).
- [ ] "Active/Passive Failover" section added to `phase-2/07-operations.md`.
- [ ] `esl_datapipeline_no_successful_run_36h` alert configured.

## Rollback

- Revert the PR that added `suspend:` to the CronJob template. Both clusters resume active/active (datapipeline fires on both). No DB or lease state to clean up.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ~~`helmParameters` not flowing through~~ | ~~Medium~~ | **Resolved** — verified on PP ArgoCD Application. |
| Typo in `activeCluster` value → both clusters suspended → no datapipeline runs | Low | `helm lint` + pre-sync render verification catches it. `esl_datapipeline_no_successful_run_36h` alert catches it at runtime. |
| Ops forgets to flip `activeCluster` during a prd outage | Medium | Runbook + oncall alert. Explicit ownership in oncall playbook. |
| ~~PP redundant cluster name unknown / unconfirmed~~ | ~~Low~~ | **Resolved** — `oshift-pp-mts1` / `oshift-pp-rba1` confirmed. |

## Out of scope (explicit)

- Automatic failover — that's Option 3.
- Any DB schema changes.
- Any Go code changes.
- `datafetch` active/passive.
- Any throughput or scaling work on event-publisher (see `plans/drafts/event-publisher-parallel-publishing.md`).

## Links

- Comparison report: `01-config-driven-suspend.md` (same directory)
- Option 3 draft for future auto-failover: `esl-documentation/plans/drafts/active-passive-deployment-scheduler.md`
- Event-publisher throughput draft: `esl-documentation/plans/drafts/event-publisher-parallel-publishing.md`
- Production scale context: `project_production_scale.md` (memory)
