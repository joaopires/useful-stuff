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

- `helm lint` across all environments
- `helm template --show-only templates/eventpublisher-deployment.yaml` renders correctly
- `helm template --show-only templates/datapipeline-cronjob.yaml` includes CDC config
