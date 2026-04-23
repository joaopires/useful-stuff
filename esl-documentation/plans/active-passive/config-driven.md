# Active/Passive Orchestration — Config-Driven Suspend (Option 1)

## Context

The ESL Orchestrator is deployed to two production OpenShift clusters (`oshift-prd-mts1` primary and `oshift-prd-rba1` redundant) in an active/active pattern. Both clusters run the same workloads:

- **`datapipeline`** CronJob — fires at the same scheduled time on both clusters, doubling Vusion API quota consumption on every run. **Active today, quota-doubling in production.**
- **`event-publisher`** Deployment (Phase 2, not yet in production) — polls the same `event_outbox` table and publishes to Solace. `FOR UPDATE SKIP LOCKED` prevents duplicate publishes but both pods compete for work, doubling DB polling and Solace sessions. The backlog-recovery ordering edge case also disappears if only one pod is active.
- **`datafetch`** REST API — stateless; stays active/active for load distribution. Out of scope.

**Decision (2026-04-17, updated 2026-04-22):** proceed with Option 1 from the comparison reports at `esl-documentation/plans/active-passive/` — render-time suspension driven by a shared `activeCluster` value and the `clusterName` injected via ArgoCD `helmParameters`. Manual failover via a one-line edit to the ESL values file. Roll out in two phases: **Phase A** applies active/passive to `datapipeline` only (before Phase 2 / PR #30); **Phase B** extends it to `event-publisher` after PR #30 merges.

Option 3 (Deployment + internal scheduler + DB lease, with automatic failover) is deferred to a future release — see `plans/drafts/active-passive-deployment-scheduler.md`.

## Goal

### Phase A (this PR — before PR #30)

Ensure `datapipeline` runs **only on the currently-designated active cluster**. This:

- Halves Vusion API quota consumption (from the datapipeline CronJob).
- Establishes the failover convention (a single `activeCluster` value) that the whole platform will adopt.

### Phase B (follow-up — after PR #30 merges)

Extend the same `activeCluster` gating to `event-publisher`. This:

- Halves DB polling and Solace sessions (from the event-publisher Deployment).
- Eliminates the backlog-recovery ordering risk on event-publisher.

## Scope

- **Phase A (in scope now)**
  - `datapipeline` CronJob (`esl/k8s/helm/templates/datapipeline-cronjob.yaml`).
  - New top-level shared `activeCluster` value in the ESL chart values files.
  - ArgoCD foundations changes to pass `clusterName` into the ESL chart via `helmParameters` — **DONE** by DevOps.
- **Phase B (after PR #30 merges)**
  - `event-publisher` Deployment (`esl/k8s/helm/templates/eventpublisher-deployment.yaml`) — add conditional `replicas` using the same `activeCluster` mechanism.
- **Out of scope**
  - `datafetch` REST API — stays active/active.
  - Any DB-backed lease primitive, internal scheduler, or Deployment refactor of datapipeline — that's Option 3.
  - Automatic failover — manual edit of `activeCluster` is the chosen mechanism.

## Prerequisites (resolve before starting Step 3)

1. ~~**Ops confirms `clusterName` values**~~ — **DONE (2026-04-22).** Confirmed values: `rba-d1` (dev, single cluster), `oshift-pp-mts1` / `oshift-pp-rba1` (PP), prd TBD.
2. ~~**ArgoCD `helmParameters` set up**~~ — **DONE (2026-04-22).** DevOps confirmed `clusterName` is passed via `helm.parameters` in the ArgoCD Application (verified on PP).
3. **Vusion quota reset mechanics confirmed** (calendar-day vs rolling 24h) — informs the runbook's failover urgency guidance for datapipeline.
4. **Phase 2 k8s PR #30 merged** — required only for Phase B (event-publisher). Phase A (datapipeline) proceeds independently.

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

  eventpublisher-deployment.yaml:                              <-- Phase B (after PR #30)
    spec:
      replicas: {{ if eq .Values.clusterName .Values.activeCluster }}
                    {{ $ep.replicaCount | default 1 }}
                {{ else }}0{{ end }}

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
| prd | TBD | TBD |

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

### ~~Step 3 — ESL chart changes (Phase A — datapipeline only)~~ DONE

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

**3d. Verification:**

- Run `helm lint` against all three env values files as usual (existing CI already does this).
- Run `helm template` locally with `--set clusterName=oshift-pp-rba1` and `--set clusterName=oshift-pp-mts1` to confirm `suspend` flips correctly.
- Open PR to testing branch, let the testing cluster exercise it.

### Step 4 — Dev rollout

After PR merges and is promoted to dev:

1. Confirm Argo applied the manifest on `rba-d1` (only cluster):
   - `kubectl get cronjob -n instore-esl-orchestrator-dev orchestrator-esl-datapipeline -o jsonpath='{.spec.suspend}'` returns `false` (since `clusterName` == `activeCluster`).
2. Observe one scheduled datapipeline run; confirm `esl.sync_state` shows one row.
3. Dev has a single cluster so no failover test is possible here — proceed to PP.

### Step 5 — PP rollout

Promoted once dev runs for at least one full scheduled window without regression.

1. Confirm on `oshift-pp-rba1` (active): CronJob `suspend: false`.
2. Confirm on `oshift-pp-mts1` (passive): CronJob `suspend: true`, no Job created at scheduled time.
3. Observe one scheduled datapipeline run on `oshift-pp-rba1`; confirm `esl.sync_state` shows one row.
4. Exercise a failover: flip `activeCluster` to `oshift-pp-mts1` in `values-pp.yaml`, push, wait for Argo. Verify next-day datapipeline fires on mts1 and is suspended on rba1. Flip back.

Datapipeline schedule in PP: `00 12 * * *` (noon).

### Step 6 — Production rollout

After PP stable for ≥ 1 week with at least one successful manually-triggered failover. Prd cluster names must be confirmed before this step.

- Add `activeCluster` to `values-prd.yaml` with the chosen primary cluster name.
- Deploy during a low-traffic window (outside 19:00 Lisbon).
- Wait for 19:00. Confirm:
  - Active cluster: `orchestrator-esl-datapipeline-<timestamp>` Job exists and runs.
  - Passive cluster: no Job created (CronJob is suspended).
  - `esl.sync_state`: exactly one row for `esl-orchestrator-prd` with the expected timestamp.
  - Vusion quota usage (ops dashboard) halved relative to prior baseline.

### Step 7 — Phase B: extend to event-publisher (after PR #30 merges)

After Phase 2 k8s PR #30 is merged and event-publisher is deployed:

Add conditional `replicas` to `helm/templates/eventpublisher-deployment.yaml`:

```yaml
spec:
  replicas: {{ if eq .Values.clusterName .Values.activeCluster }}{{ $ep.replicaCount | default 1 }}{{ else }}0{{ end }}
```

This preserves the existing `replicaCount` semantics for the active cluster (default 1, overridable) while forcing 0 on the passive cluster. Same `activeCluster` value already in place — no values file changes needed.

### Step 8 — Runbook + observability

- Write a short failover runbook at `esl-documentation/runbooks/esl-orchestrator-failover.md` (create `runbooks/` dir if not present) covering:
  - How to identify primary cluster is unhealthy.
  - How to edit `activeCluster` in the correct env's values file.
  - How to confirm Argo applied the change on both clusters.
  - Post-failover verification: CronJob `suspend` flipped, next scheduled run fires on new cluster.
  - Rollback (flip the value back).
- Add Prometheus alert (place in `values-observability.yaml` alongside existing alerts):
  - `esl_datapipeline_no_successful_run_36h` — fires if `esl.sync_state` has no `sync_status = 'SUCCESS'` row for `esl-orchestrator-prd` in the last 36 hours.
  - After Phase B: `esl_eventpublisher_no_active_pod` — fires if both clusters' event-publisher Deployments show 0 ready replicas for >5 min.

## Verification checklist

### Phase A (sign off per environment)

- [ ] `helm template` renders `suspend: false` on active cluster and `suspend: true` on passive cluster.
- [ ] ArgoCD Application `spec.sources[0].helm.parameters` contains `clusterName` in each cluster.
- [ ] `kubectl get cronjob ... -o jsonpath='{.spec.suspend}'` returns the expected boolean per cluster.
- [ ] One scheduled datapipeline window observed: only the active cluster's Job is created.
- [ ] `esl.sync_state` shows exactly one success row per schedule tick.
- [ ] Failover test executed in PP (flip `activeCluster`, confirm CronJob suspend flips, flip back).
- [ ] Runbook published.
- [ ] `esl_datapipeline_no_successful_run_36h` alert configured.

### Phase B (after PR #30, sign off per environment)

- [ ] `helm template` renders `replicas: 1` on active and `replicas: 0` on passive.
- [ ] `kubectl get deployment orchestrator-esl-eventpublisher -o jsonpath='{.spec.replicas}'` returns expected count per cluster.
- [ ] On the passive cluster, `kubectl get pods | grep eventpublisher` returns no results.
- [ ] On the active cluster, event-publisher logs show polling activity and delivered-event counts.
- [ ] `esl_eventpublisher_no_active_pod` alert configured.

## Rollback

- **Phase A:** revert the PR that added `suspend:` to the CronJob template. Both clusters resume active/active (datapipeline fires on both). No DB or lease state to clean up.
- **Phase B:** revert just the `replicas:` expression in `eventpublisher-deployment.yaml`. Event-publisher scales back to `replicaCount` on both clusters.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ~~`helmParameters` not flowing through~~ | ~~Medium~~ | **Resolved** — verified on PP ArgoCD Application. |
| Typo in `activeCluster` value → both clusters suspended → no datapipeline runs | Low | `helm lint` + pre-sync render verification catches it. `esl_datapipeline_no_successful_run_36h` alert catches it at runtime. |
| Ops forgets to flip `activeCluster` during a prd outage | Medium | Runbook + oncall alert. Explicit ownership in oncall playbook. |
| ~~PP redundant cluster name unknown / unconfirmed~~ | ~~Low~~ | **Resolved** — `oshift-pp-mts1` / `oshift-pp-rba1` confirmed. |
| Phase B conflicts with PR #30 changes to `eventpublisher-deployment.yaml` | Low | Phase B is a follow-up PR after PR #30 merges — no conflict possible. |

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
