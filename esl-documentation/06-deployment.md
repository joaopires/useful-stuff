# Deployment & Infrastructure

## Overview

The ESL Orchestrator is deployed on Kubernetes using Helm charts and managed by ArgoCD (GitOps). Each environment runs in its own namespace with environment-specific configuration.

The deployment consists of three workload types:

| Component | K8s Resource | Purpose |
|---|---|---|
| Database Migrations | Job (PreSync) | Flyway schema migrations — must succeed before other components deploy |
| Data Pipeline | CronJob | Scheduled data synchronisation |
| DataFetch API | Deployment + Service + Ingress | Continuously running REST API |

## ArgoCD Deployment Flow

ArgoCD manages the deployment lifecycle using sync hooks to enforce ordering:

![Deployment Flow](diagrams/deployment-flow.svg)

### PreSync Phase (Weight 0)

The following resources are created first:

- **NetworkPolicy** — allows the migration job to reach the database
- **ServiceAccount** — identity for the migration job
- **ExternalSecret** — pulls Flyway credentials from Vault

These resources are deleted automatically after a successful sync (`HookSucceeded` deletion policy).

### PreSync Phase (Weight 1)

- **Flyway Migration Job** — runs schema migrations against PostgreSQL
- Backoff limit: `0` — if the job fails, the entire sync is aborted
- This prevents deploying application code that depends on a schema change that hasn't been applied

### Sync Phase

Once migrations succeed, the remaining resources are deployed:

- DataFetch API: Deployment, Service, Ingress, ExternalSecrets
- Data Pipeline: CronJob, ConfigMap, ExternalSecrets
- NetworkPolicy (main)

## Helm Chart

The chart (`instore-esl-orchestrator`, version `0.1.1`) is templated across environments using values files:

```
helm/
├── Chart.yaml
└── templates/
    ├── datafetch-api.yaml        # Deployment + Service + Ingress
    ├── datapipeline-cronjob.yaml # CronJob + ConfigMap
    ├── dbmigrations.yaml         # PreSync Job + hooks
    └── network-policy.yaml       # NetworkPolicy
```

Each environment has its own values directory:

```
clusters/
├── cluster-dev/
│   ├── values-dev.yaml
│   ├── values-security-dev.yaml
│   └── values-observability-dev.yaml
├── cluster-preproduction/
│   ├── values-pp.yaml
│   ├── values-security-pp.yaml
│   └── values-observability-pp.yaml
└── cluster-production/
    ├── values-prd.yaml
    ├── values-security-prd.yaml
    └── values-observability.yaml
```

## Resource Allocation

### DataFetch API

| Setting | Value |
|---|---|
| Replicas | 1 |
| CPU request / limit | 100m / 250m |
| Memory request / limit | 64Mi / 128Mi |
| Container port | 8080 |
| Service port | 80 → 8080 |

### Data Pipeline (CronJob)

| Setting | Value |
|---|---|
| CPU request / limit | 250m / 1000m |
| Memory request / limit | 512Mi / 1Gi |
| Concurrency policy | Forbid (no overlapping runs) |
| Backoff limit | 3 |
| TTL after finished | 600s |
| History (success/fail) | 2 / 2 |

### Database Migrations (PreSync Job)

| Setting | Value |
|---|---|
| CPU request / limit | 50m / 250m |
| Memory request / limit | 128Mi / 256Mi |
| Backoff limit | 0 (abort on failure) |

## Container Security

All containers run with the same hardened security context:

```yaml
securityContext:
  privileged: false
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1002
  capabilities:
    drop: [ALL]
podSecurityContext:
  fsGroup: 2000
  seccompProfile:
    type: RuntimeDefault
```

## Health Probes (DataFetch API)

| Probe | Path | Initial Delay | Period | Failure Threshold |
|---|---|---|---|---|
| Startup | `/monitoring/ping` | 15s | 10s | 3 |
| Readiness | `/monitoring/pong` | 5s | 10s | 3 |
| Liveness | `/monitoring/ping` | 5s | 10s | 6 |

The readiness probe (`/monitoring/pong`) checks database connectivity. The DataFetch API is removed from the Service endpoints if the database becomes unreachable.

## Secret Management

Secrets are managed by the **External Secrets Operator**, which synchronises credentials from HashiCorp Vault into Kubernetes Secrets every 5 minutes.

### Vault Paths

All secrets are stored under the `instore/instore-orchestrator/` Vault path:

| Secret Group | Vault Path | Contents |
|---|---|---|
| Database | `instore/instore-orchestrator/database` | DB host, port, username, password, database name, schema |
| Flyway | `instore/instore-orchestrator/database` | Flyway user, password, schemas, host, port, database |
| Connectors | `instore/instore-orchestrator/application` | Vusion Manager and VLink API credentials (URLs, keys) |
| TLS | `security/certificate/instore/instore-orchestrator` | Ingress TLS certificate and key |

Each environment uses environment-specific property names within the same Vault paths (e.g., `instore_orchestrator_esl_pp_db_username` for preproduction).

### Secret Injection

Secrets are injected as environment variables into containers:

**DataFetch API:** `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SCHEMA`

**Data Pipeline:** Sink DB credentials (`SINK_POSTGRES_*`), state store DB credentials (`CONNECTOR_SYNC_STATE_STORE_POSTGRES_*`), Vusion Manager credentials (`CONNECTOR_VUSION_MANAGER_*`), VLink credentials (`CONNECTOR_VLINK_*`)

**Flyway:** `FLYWAY_USER`, `FLYWAY_PASSWORD`, `FLYWAY_SCHEMAS`, `FLYWAY_DB_HOST`, `FLYWAY_DB_PORT`, `FLYWAY_DB_NAME`

## Network Policies

Network traffic is restricted using Kubernetes NetworkPolicies.

### Ingress Rules

| Source | Target Port | Purpose |
|---|---|---|
| Traefik ingress (`ingress-instore` namespace) | 8080/TCP | External API access |
| Pods in same namespace | (any) | Inter-pod communication |

### Egress Rules

| Destination | Target Port | Purpose |
|---|---|---|
| PostgreSQL nodes | 10200/TCP (PP) / 5432/TCP (dev/prd) | Database connections |
| `kube-system/kube-dns` | 53/UDP | DNS resolution |
| `observability/otlp-collector` | 4317/TCP | OpenTelemetry traces |

### Database CIDRs (Preproduction)

Preproduction connects to three PostgreSQL replicas:

- `10.50.136.6/32` (port 10200)
- `10.50.136.7/32` (port 10200)
- `10.49.136.10/32` (port 10200)

Development and production use placeholder IPs (`10.0.0.1/32`) pending final infrastructure provisioning.

## Ingress

The DataFetch API is exposed via a Traefik ingress with TLS termination:

| Environment | Hostname |
|---|---|
| Development | `orchestrator-esl-datafetch-api-dev.corp.mc.pt` |
| Preproduction | `orchestrator-esl-datafetch-api-pp.corp.mc.pt` |
| Production | `orchestrator-esl-datafetch-api-prd.corp.mc.pt` |

- Entrypoint: `websecure` (HTTPS only)
- TLS certificates are sourced from Vault via External Secrets Operator
- Ingress class: `traefik-instore`

## Environment Differences

| Setting | Development | Preproduction | Production |
|---|---|---|---|
| **Namespace** | `instore-esl-orchestrator-dev` | `instore-esl-orchestrator-pp` | `instore-esl-orchestrator-prd` |
| **Pipeline schedule** | `0 3 * * *` (3:00 AM) | `40 01 * * *` (1:40 AM) | `0 3 * * *` (3:00 AM) |
| **Store filter** | All stores | 9 specific stores | All stores |
| **DB port** | 5432 | 10200 | 5432 |
| **Image tags** | Placeholder | Active | Placeholder |
| **Secrets** | Placeholder | Configured | Placeholder |

> **Note:** Development and production environments have placeholder values for image tags, secrets, and database CIDRs. These are populated when the environments are provisioned.

## Monitoring and Alerting

Prometheus alert rules are deployed via the observability values file. Two alert groups are configured per environment:

### Infrastructure Alerts

- Pod crash loops
- Pod not ready (> 15 min)
- Deployment rollout stuck
- Job completion failures
- Container waiting state

### Application Alerts

| Alert | Condition | Severity |
|---|---|---|
| HTTP 5xx error rate > 10% | 15 min window | Critical |
| HTTP 5xx error rate 5–10% | 15 min window | Warning |
| HTTP p95 latency > 3s | 5 min window | Info |
| Average response time > 1s | 5 min window | Info |

Health check (`/monitoring/ping`) and metrics (`/metrics`) endpoints are excluded from alert calculations.

A global `maintenance` flag can be set to `on` to suppress all alerts during planned maintenance windows.
