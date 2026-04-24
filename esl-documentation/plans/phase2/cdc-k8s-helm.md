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
- ExternalSecret (DB creds from existing Vault path + Solace OAuth2 client credentials from new entries)
- ConfigMap (publisher config: host, vpn, auth_scheme, token_endpoint, scope, topic_prefix, poll interval, batch size, log level)
- Deployment (1 replica, health probes, security context matching existing pattern)

New Vault entries at `{vaultBasePath}/solace` (KV-structured, two properties only):

- `client-id` — OAuth2 client ID
- `client-secret` — OAuth2 client secret

Non-sensitive Solace config (host, vpn, token_endpoint, scope, topic_prefix) lives in the per-env values file, not Vault. `auth_scheme` is hardcoded to `oauth2` in the ConfigMap.

## 3. Values updates

Per-env `values-{env}.yaml`:

```yaml
dataPipeline:
  config:
    cdc:
      enabled: false  # flip to true during event-publisher rollout

eventPublisher:
  imageTag: "<image tag>"
  replicaCount: 1
  timeZone: "Europe/Lisbon"
  config:
    solace:
      host: "event-broker-<env>.corp.mc.pt:55443"   # per-env broker host:port (tcps:// prefix added by template)
      vpn: "<vpn-name>"                             # per-env VPN
      tokenEndpoint: "https://identity[-pp].sonaemc.com/connect/token"
      scope: "solace"
      topicPrefix: "in-store/orchestratoresl"
    publisher:
      pollInterval: "1s"
      batchSize: 100
      shutdownTimeout: "30s"
    log:
      level: "info"
```

Per-env `values-security-{env}.yaml`:

Egress rule to the Solace broker — TBD pending Ops confirmation on whether connectivity is via:

- **In-cluster gateway pod** (`podsSelector` rule targeting `namespace: solace-cloud`, labels `app: solace`, port `55443`), or
- **Direct external egress** (`cidrs` rule with the resolved broker IPs, port `55443`).

OAuth2 also requires egress to the identity server (`identity[-pp].sonaemc.com`) — TBD whether the existing `internet 0.0.0.0/0 except 10.0.0.0/8 port 443` rule covers it or an explicit CIDR is needed.

## Verification

- `helm template --show-only templates/eventpublisher-deployment.yaml` renders correctly (no missing required values)
- `helm template --show-only templates/datapipeline-cronjob.yaml` includes CDC config

### Solace networking

Integration team provided corporate broker hostnames (`event-broker-*.corp.mc.pt:55443`) for all three envs. Whether those resolve through an in-cluster gateway pod (original assumption) or require direct external egress is TBD pending Ops confirmation. Update the `values-security-{env}.yaml` egress rule once confirmed.

### Deferred items — requires real operational values

`helm lint` is clean. `kubectl apply` / ArgoCD will still fail on the cluster until these are in place:

| Item | Location | Needed from | Failure mode |
|---|---|---|---|
| Vault entries at `{vaultBasePath}/solace` (`client-id`, `client-secret`) per env | External Vault | Ops (already populated per user) | ExternalSecret reconcile fails, Secret never materializes, Deployment stuck |
| NetworkPolicy egress rule for Solace broker (gateway pod or external CIDR) | `values-security-{env}.yaml` | Ops (connectivity model TBD) | Pod starts but readiness fails (publisher can't reach broker) |
| NetworkPolicy egress rule for OAuth2 identity server | `values-security-{env}.yaml` | Ops (confirm CIDR vs existing internet rule) | Pod starts but readiness fails (token acquisition blocked) |

When real values land:

1. Update `values-security-{env}.yaml` with the confirmed egress rules
2. Re-run `helm lint` across all clusters (loop from k8s CLAUDE.md) — should still be 0 errors
3. `helm template` + diff against `kubectl apply --dry-run=server` to catch API-level validation
4. Flip `dataPipeline.config.cdc.enabled` to `true` per env once the publisher is verified

## Diagrams

Create Excalidraw diagrams (exported as SVG) in `esl-documentation/phase-2/diagrams/`, following the Phase 1 convention:

- K8s environment — all resources (Deployments, CronJobs, Services, ConfigMaps, ExternalSecrets, NetworkPolicies) and how they connect (DB, Solace, Vault)
- Deployment flow — rollout sequence for the new event-publisher alongside existing components
