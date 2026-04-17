# Active/Passive Orchestration — Config-Driven Suspend (Option 1)

## Context

The ESL Orchestrator is deployed to two production OpenShift clusters (`oshift-prd-mts1` primary and `oshift-prd-rba1` redundant) in an active/active pattern. Both clusters run the same workloads:

- **`datapipeline`** CronJob — fires at the same scheduled time on both clusters, doubling Vusion API quota consumption on every run. **Active today, quota-doubling in production.**
- **`event-publisher`** Deployment (Phase 2, not yet in production) — polls the same `event_outbox` table and publishes to Solace. `FOR UPDATE SKIP LOCKED` prevents duplicate publishes but both pods compete for work, doubling DB polling and Solace sessions. The backlog-recovery ordering edge case also disappears if only one pod is active.
- **`datafetch`** REST API — stateless; stays active/active for load distribution. Out of scope.

**Decision (2026-04-17):** proceed with Option 1 from the comparison reports at `esl-documentation/plans/active-passive/` — render-time suspension driven by a shared `activeCluster` value and the `clusterName` injected via ArgoCD `helmParameters`. Manual failover via a one-line edit to the ESL values file. Apply to **both** `datapipeline` and `event-publisher` now; undo the event-publisher half later if it causes trouble.

Option 3 (Deployment + internal scheduler + DB lease, with automatic failover) is deferred to a future release — see `plans/drafts/active-passive-deployment-scheduler.md`.

## Goal

Across the active/active production cluster pair, ensure that both stateful-writer workloads (`datapipeline` and `event-publisher`) run **only on the currently-designated active cluster**. This:

- Halves Vusion API quota consumption (from the datapipeline CronJob).
- Halves DB polling and Solace sessions (from the event-publisher Deployment).
- Eliminates the backlog-recovery ordering risk on event-publisher.
- Establishes the failover convention (a single `activeCluster` value) that the whole platform will adopt.

## Scope

- **In scope**
  - `datapipeline` CronJob (`esl/k8s/helm/templates/datapipeline-cronjob.yaml`).
  - `event-publisher` Deployment (`esl/k8s/helm/templates/eventpublisher-deployment.yaml`).
  - ArgoCD foundations changes to pass `clusterName` into the ESL chart via `helmParameters`.
  - New top-level shared `activeCluster` value in the ESL chart values files.
- **Out of scope**
  - `datafetch` REST API — stays active/active.
  - Any DB-backed lease primitive, internal scheduler, or Deployment refactor of datapipeline — that's Option 3.
  - Automatic failover — manual edit of `activeCluster` is the chosen mechanism.

## Prerequisites (resolve before starting Step 2)

1. **Ops confirms `clusterName` values** set at `helm install` time on each physical Argo instance — for dev, PP primary, PP redundant (if it exists), `oshift-prd-mts1`, `oshift-prd-rba1`. Already observed `oshift-pp-mts1` in pod labels; remaining values assumed but unverified.
2. **Phase 2 k8s PR #30 is merged and deployed** — this plan edits `eventpublisher-deployment.yaml` from that PR; doing the work before PR #30 merges risks merge conflicts.
3. **Vusion quota reset mechanics confirmed** (calendar-day vs rolling 24h) — informs the runbook's failover urgency guidance for datapipeline.

## Architecture after implementation

```
[ArgoCD foundations repo]
  clusters/cluster-production/values-prd.yaml
    applications[instore-esl-orchestrator].sources[0].helmParameters:   <-- NEW
      - name: clusterName
        value: <per-cluster identity>
        forceString: true

                    │ each physical Argo renders with its own clusterName
                    ▼
[ESL helm chart]
  values-prd.yaml:
    activeCluster: "oshift-prd-mts1"                           <-- NEW (top-level)
    dataPipeline: { schedule: "00 19 * * *", ... }             <-- unchanged
    eventPublisher: { replicaCount: 1, ... }                   <-- unchanged

  datapipeline-cronjob.yaml:
    spec:
      suspend: {{ ne .Values.clusterName .Values.activeCluster }}  <-- NEW
      schedule: {{ $dp.schedule | quote }}

  eventpublisher-deployment.yaml:
    spec:
      replicas: {{ if eq .Values.clusterName .Values.activeCluster }}
                    {{ $ep.replicaCount | default 1 }}
                {{ else }}0{{ end }}                            <-- NEW

Rendered on oshift-prd-mts1 (active):
  CronJob.suspend = false        -> fires at 19:00
  Deployment.replicas = 1        -> pod runs, polls outbox

Rendered on oshift-prd-rba1 (passive):
  CronJob.suspend = true         -> scheduled but never fires
  Deployment.replicas = 0        -> no pod
```

## Implementation steps

### Step 1 — Verify cluster identities (prerequisite 1)

Ask ops for the exact `clusterName` flag passed to `helm install` on each physical Argo. Record in the runbook. Expected values (to be confirmed):

| Environment | Active (primary) | Passive (redundant) |
|---|---|---|
| dev | `oshift-dev-???` | n/a |
| pp | `oshift-pp-mts1` (confirmed in pod labels) | `oshift-pp-???` |
| prd | `oshift-prd-mts1` | `oshift-prd-rba1` |

Block further steps until all six values are confirmed.

### Step 2 — Foundations repo PR (cross-team)

Repo: `kubernetes-foundations-instore`

In each of the following files, locate the `instore-esl-orchestrator` Application in the `applications:` list, inside `sources[0]`, and add a `helmParameters` block:

- `clusters/cluster-dev/values-dev.yaml`
- `clusters/cluster-preproduction/values-pp.yaml`
- `clusters/cluster-production/values-prd.yaml`

Diff (conceptual — exact value may be pass-through via `$.Values.clusterName` if the foundations template supports that inside the `sources` range, or hardcoded per-cluster if templating-within-templating is awkward; choose the simplest working approach during implementation):

```yaml
sources:
- repoURL: 'https://github.com/sonaemc-kubernetes/lac1041-instore-orchestrator-esl.git'
  targetRevision: main
  path: helm
  helmValues:
  - path: ../clusters/cluster-production/values-prd.yaml
  - path: ../clusters/cluster-production/values-observability.yaml
  - path: ../clusters/cluster-production/values-security-prd.yaml
  helmParameters:                 # NEW
  - name: clusterName             # NEW
    value: oshift-prd-mts1        # NEW — or dynamic; each cluster's bootstrap sets its own
    forceString: true             # NEW
```

PR, review, merge. Verify that each cluster's Argo-rendered `instore-esl-orchestrator` Application now shows `spec.sources[0].helm.parameters` containing `clusterName` with the correct value.

### Step 3 — ESL chart changes

Repo: `sonaemc-instore/lac1041-instoreorchestrator_esl` at `k8s/`.

Follow the k8s feature-branch rule (`feedback_k8s_no_direct_testing.md`): open a feature branch, raise a PR to the testing branch.

**3a. Add top-level `activeCluster` to each env values file:**

`clusters/cluster-production/values-prd.yaml`:

```yaml
namespace: instore-esl-orchestrator
stream: instore
clusterEnvironment: onprem
vaultBasePath: instore/instore-orchestrator_esl

activeCluster: "oshift-prd-mts1"    # NEW — shared by datapipeline + eventPublisher

dataFetch:
  # ... unchanged ...
dataPipeline:
  # ... unchanged (no per-component activeCluster) ...
eventPublisher:
  # ... unchanged ...
```

Same pattern in `values-pp.yaml` (use the PP primary name) and `values-dev.yaml` (use the dev cluster name).

**3b. Add `suspend` to the datapipeline CronJob template:**

`helm/templates/datapipeline-cronjob.yaml`, inside the CronJob `spec:` block around line 261:

```yaml
spec:
  suspend: {{ ne .Values.clusterName .Values.activeCluster }}   # NEW
  schedule: {{ $dp.schedule | quote }}
  timeZone: {{ $dp.timeZone | default "UTC" | quote }}
  # ... rest unchanged ...
```

**3c. Add conditional `replicas` to the event-publisher Deployment template:**

`helm/templates/eventpublisher-deployment.yaml`, around line 171:

```yaml
spec:
  replicas: {{ if eq .Values.clusterName .Values.activeCluster }}{{ $ep.replicaCount | default 1 }}{{ else }}0{{ end }}   # MODIFIED
  selector:
    matchLabels:
      app: {{ $name }}
  # ... rest unchanged ...
```

This preserves the existing `replicaCount` semantics for the active cluster (default 1, overridable) while forcing 0 on the passive cluster.

**3d. Update CLAUDE.md guidance** in `esl/k8s/CLAUDE.md` to clarify that the rule against `if .Values.X` conditional guards around whole resources still holds, but render-time boolean / conditional expressions on first-class fields (`suspend`, `replicas`) are acceptable.

**3e. Verification:**

- Run `helm lint` against all three env values files as usual (existing CI already does this).
- Run `helm template` locally for each cluster with and without `--set clusterName=oshift-prd-mts1` to confirm both `suspend` and `replicas` flip correctly.
- Open PR to testing branch, let the testing cluster exercise it.

### Step 4 — Dev rollout

After PR merges and is promoted to dev:

1. Confirm Argo applied the manifest on the active dev cluster:
   - `kubectl get cronjob -n instore-esl-orchestrator-dev orchestrator-esl-datapipeline -o jsonpath='{.spec.suspend}'` returns `false`.
   - `kubectl get deployment -n instore-esl-orchestrator-dev orchestrator-esl-eventpublisher -o jsonpath='{.spec.replicas}'` returns `1` (or whatever `replicaCount` is).
2. If there's a second dev cluster, confirm:
   - CronJob `suspend: true`.
   - Deployment `replicas: 0` and no `orchestrator-esl-eventpublisher-*` pods.
3. Observe one scheduled datapipeline run on the active cluster; confirm `esl.sync_state` shows one row.
4. Observe event-publisher logs on the active cluster show polling; passive cluster has no pod.
5. Flip `activeCluster` in `values-dev.yaml`, push, wait for Argo. Observe the former-passive becomes the active — CronJob suspend flips, Deployment scales up, and event-publisher starts polling.

### Step 5 — PP rollout

Same as dev, promoted once dev runs for at least one full scheduled window without regression.

- Datapipeline schedule: `00 12 * * *` (noon).
- Event-publisher: observe immediately after deploy (Deployment pods come up quickly).
- Exercise a failover: flip `activeCluster` to the redundant PP cluster; verify next-day datapipeline fires there and event-publisher pod moves there; flip back.

### Step 6 — Production rollout

After PP stable for ≥ 1 week with at least one successful manually-triggered failover:

**Gate:** Phase 2 k8s PR #30 must be merged and the event-publisher component deployed in prd (even in its initial active/active state) before this plan's prd rollout. Sequence:

1. PR #30 merges → event-publisher deployed active/active in prd.
2. This plan's prd PR deploys the `activeCluster` gating → event-publisher scales to 0 on rba1; datapipeline CronJob suspends on rba1.

Then:

- Deploy during a low-traffic window (outside 19:00 Lisbon).
- Wait for 19:00. Confirm:
  - `oshift-prd-mts1`: `orchestrator-esl-datapipeline-<timestamp>` Job exists and runs.
  - `oshift-prd-rba1`: no Job created (CronJob is suspended).
  - `oshift-prd-mts1`: event-publisher pod running and polling.
  - `oshift-prd-rba1`: event-publisher Deployment at 0 replicas; no pod.
  - `esl.sync_state`: exactly one row for `esl-orchestrator-prd` with the expected timestamp.
  - Vusion quota usage (ops dashboard) halved relative to prior baseline.
  - Solace connections halved (one session instead of two).

### Step 7 — Runbook + observability

- Write a short failover runbook at `esl-documentation/runbooks/esl-orchestrator-failover.md` (create `runbooks/` dir if not present) covering:
  - How to identify primary cluster is unhealthy.
  - How to edit `activeCluster` in the correct env's values file.
  - How to confirm Argo applied the change on both clusters.
  - Post-failover verification: CronJob `suspend` flipped, event-publisher pod moved, next 19:00 fires on new cluster.
  - Rollback (flip the value back).
- Add Prometheus alert (place in `values-observability.yaml` alongside existing alerts):
  - `esl_datapipeline_no_successful_run_36h` — fires if `esl.sync_state` has no `sync_status = 'SUCCESS'` row for `esl-orchestrator-prd` in the last 36 hours.
  - Consider also: `esl_eventpublisher_no_active_pod` — fires if both clusters' event-publisher Deployments show 0 ready replicas for >5 min (catches the misconfiguration where `activeCluster` is typo'd into a value matching neither cluster).

## Verification checklist (sign off per environment)

- [ ] `helm template` renders `suspend: false` / `replicas: 1` on primary and `suspend: true` / `replicas: 0` on redundant (manually verified for each env).
- [ ] ArgoCD Application `spec.sources[0].helm.parameters` contains `clusterName` in each cluster.
- [ ] `kubectl get cronjob ... -o jsonpath='{.spec.suspend}'` returns the expected boolean per cluster.
- [ ] `kubectl get deployment orchestrator-esl-eventpublisher -o jsonpath='{.spec.replicas}'` returns the expected count per cluster.
- [ ] On the passive cluster, `kubectl get pods | grep eventpublisher` returns no results.
- [ ] One scheduled datapipeline window observed: only the primary's Job is created.
- [ ] `esl.sync_state` shows exactly one success row per schedule tick.
- [ ] On the active cluster, event-publisher logs show polling activity and delivered-event counts.
- [ ] Failover test executed (flip, confirm both workloads moved, flip back).
- [ ] Runbook published.
- [ ] Alerts configured and wired into the oncall rotation.

## Rollback

- Revert the PR that added `suspend:` and `replicas:` expressions to the templates.
- Both clusters resume active/active (datapipeline CronJob fires on both; event-publisher scales back to `replicaCount: 1` on both).
- No DB or lease state to clean up.
- Partial rollback: to revert only the event-publisher change (keep datapipeline active/passive), revert just the `replicas:` expression in `eventpublisher-deployment.yaml`.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `helmParameters` not flowing through because of templating-within-templating edge case in foundations chart | Medium | Verify `spec.sources[0].helm.parameters` in the rendered Argo Application for each cluster before proceeding. If templating fails, hardcode per-cluster `value:` in each foundations cluster values file. |
| Typo in `activeCluster` value → both clusters suspended / 0 replicas → no work runs | Low | `helm lint` + pre-sync render verification catches it. Secondary alert `esl_eventpublisher_no_active_pod` catches it at runtime. |
| Ops forgets to flip `activeCluster` during a prd outage | Medium | Runbook + oncall alert. Explicit ownership in oncall playbook. |
| PP redundant cluster name unknown / unconfirmed | Low | Resolved by prerequisite 1 before Step 3. |
| Conflict with Phase 2 k8s PR #30 (which also edits `eventpublisher-deployment.yaml`) | Medium | Sequence: merge PR #30 first; then this plan's PR. Rebase before final merge. |
| Event-publisher in prd first rolls out active/active (before this plan lands), then scales to 0 on rba1 | Low | Brief window (minutes to hours between PR #30 rollout and this plan's prd PR). Accept; `SKIP LOCKED` prevents correctness issues during the window. |
| Rolling restart of the active cluster's event-publisher briefly drops to 0 running pods | Low | Deployment strategy is unchanged (default `RollingUpdate` with `maxUnavailable`/`maxSurge` defaults). A single replica means there's a brief gap during restart — same as today. Post-failover alerts (ready=0 for >5min) catch persistent gaps. |

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
