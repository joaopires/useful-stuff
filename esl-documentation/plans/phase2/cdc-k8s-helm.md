# Plan: phase2-cdc-k8s-helm

**Scope:** `k8s` project — Helm chart changes
**Depends on:** all other plans (deployed last)

## Critical files to modify

- `helm/templates/datapipeline-cronjob.yaml` — add CDC config to ConfigMap
- `clusters/cluster-{env}/values-{env}.yaml` — add eventPublisher + CDC flag
- `clusters/cluster-{env}/values-security-{env}.yaml` — add Solace egress rule

## New files

- `helm/templates/eventpublisher-deployment.yaml` — full component template

## 1. DataPipeline ConfigMap update

Add to the ConfigMap in `datapipeline-cronjob.yaml`:

```yaml
sink:
  postgres:
    cdc:
      enabled: {{ .Values.dataPipeline.config.cdc.enabled | default false }}
```

## 2. Event Publisher template

**New file: `helm/templates/eventpublisher-deployment.yaml`**

Following existing component-oriented pattern (self-contained):

- ServiceAccount (`sa-orchestrator-esl-eventpublisher`)
- ExternalSecret (DB creds from existing Vault path + Solace creds from new entries)
- ConfigMap (publisher config: poll interval, batch size, Solace topic prefix)
- Deployment (1 replica, health probes, security context matching existing pattern)

New Vault secrets: `{prefix}_app_solace_host`, `{prefix}_app_solace_username`, `{prefix}_app_solace_password`

## 3. Values updates

Per-env `values-{env}.yaml`:

```yaml
dataPipeline:
  config:
    cdc:
      enabled: true  # or false for rollout

eventPublisher:
  imageTag: "placeholder"
  config:
    pollInterval: "1s"
    batchSize: 100
    solace:
      topicPrefix: "esl/events"
```

Per-env `values-security-{env}.yaml`:

```yaml
netpol:
  egress:
    cidrs:
      # ... existing rules ...
      - name: solace-broker
        host: <TBD>/32
        ports:
          - port: 55555  # or 443 if TLS
            protocol: TCP
```

## Verification

- `helm template --show-only templates/eventpublisher-deployment.yaml` renders correctly (no missing required values)
- `helm template --show-only templates/datapipeline-cronjob.yaml` includes CDC config

### Solace Cloud networking

The client uses Solace Cloud (SaaS). Connection is via an in-cluster gateway pod provided by Solace, not direct internet egress. NetworkPolicy egress is modelled as a `podsSelector` rule targeting `namespace: solace-cloud`, labels `app: solace`, port `55443` (TLS SMF) — the same pattern used by other projects in this cluster. No CIDR placeholder is needed.

### Deferred items — requires real operational values

`helm lint` is clean with the placeholders below. `kubectl apply` / ArgoCD will still fail on the cluster until these are replaced:

| Placeholder | Location | Needed from | Failure mode |
|---|---|---|---|
| `eventPublisher.imageTag: "<TBD>"` / `"placeholder"` | `values-{env}.yaml` | Built + pushed image tag | Pod ImagePullBackOff |
| Vault entries at `{vaultBasePath}/solace` (host, vpn, username, password) | External Vault | Ops / credentials owner | ExternalSecret reconcile fails, Secret never materializes, Deployment stuck |
| `solace-cloud` namespace / `app: solace` gateway pod | Cluster-level infra | Solace Cloud deployment (pre-existing in pp/prd clusters) | NetworkPolicy is valid but egress has no target |

When real values land:

1. Replace imageTag placeholders across all 3 env files
2. Ensure Vault `{vaultBasePath}/solace` entries exist
3. Re-run `helm lint` across all clusters (loop from k8s CLAUDE.md) — should still be 0 errors
4. `helm template` + diff against `kubectl apply --dry-run=server` to catch API-level validation
5. Flip `dataPipeline.config.cdc.enabled` to `true` per env once the publisher is verified

## Diagrams

Create Excalidraw diagrams (exported as SVG) in `esl-documentation/phase-2/diagrams/`, following the Phase 1 convention:

- K8s environment — all resources (Deployments, CronJobs, Services, ConfigMaps, ExternalSecrets, NetworkPolicies) and how they connect (DB, Solace, Vault)
- Deployment flow — rollout sequence for the new event-publisher alongside existing components
