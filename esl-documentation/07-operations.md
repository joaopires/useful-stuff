# Operations & Maintenance

## Configuration Changes

All runtime configuration for the ESL Orchestrator is managed through Git. Changes are made in the Kubernetes deployment repository and applied automatically via ArgoCD.

### Repository

Configuration lives in the [lac1041-instore-orchestrator-esl](https://github.com/sonaemc-kubernetes/lac1041-instore-orchestrator-esl) repository. The ArgoCD application tracks a specific branch per environment (e.g., `testing` for preproduction).

### Git Workflow

1. Create a branch from the ArgoCD target revision:

```bash
git checkout testing
git pull origin testing
git checkout -b feature/<description>
```

2. Edit the relevant values file (e.g., `clusters/cluster-preproduction/values-pp.yaml`)
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/):

```bash
git add clusters/cluster-preproduction/values-pp.yaml
git commit -m "chore: update esl datapipeline schedule"
git push origin feature/<description>
```

4. Open a pull request targeting the ArgoCD target revision branch
5. After merge, ArgoCD detects the change and syncs automatically

## Common Operational Tasks

### Changing the Pipeline Schedule

Edit the `schedule` field in the environment's values file under the data pipeline CronJob section:

```yaml
- name: orchestrator-esl-datapipeline
  schedule: "0 6 * * *"   # Every day at 06:00 UTC
  timeZone: "UTC"
```

The schedule uses standard cron syntax. All times are in **UTC**.

**Examples:**

| Schedule | Meaning |
|---|---|
| `"0 6 * * *"` | Every day at 06:00 UTC |
| `"0 */6 * * *"` | Every 6 hours |
| `"0 8 * * 1-5"` | Weekdays at 08:00 UTC |
| `"0 2 * * 0"` | Every Sunday at 02:00 UTC |

> **Note:** `concurrencyPolicy: Forbid` is set, meaning a new run will be skipped if the previous one is still in progress.

### Filtering Stores

Store filters restrict which stores the pipeline processes. Edit the connector settings in the values file:

**Process specific stores:**

```yaml
connector:
  filter_stores:
    - "continente_pt.001234"
    - "bomdia_pt.009648"
```

**Process all stores from specific retail chains:**

```yaml
connector:
  filter_stores: []
  filter_retail_chains:
    - "continente_pt"
```

**Process all stores:**

```yaml
connector:
  filter_stores: []
```

> **Priority:** If `filter_stores` has entries, `filter_retail_chains` is ignored.

### Running an Ad-Hoc Pipeline Execution

To trigger the pipeline outside of its schedule, create a Job from the CronJob:

```bash
kubectl create job --from=cronjob/orchestrator-esl-datapipeline \
  manual-run-$(date +%s) \
  -n instore-esl-orchestrator-pp
```

Monitor the job:

```bash
kubectl logs -f job/manual-run-<timestamp> -n instore-esl-orchestrator-pp
```

### Checking Sync State

Query the `sync_state` table to see recent pipeline runs:

```sql
SELECT pipeline_name, sync_status, stores_processed,
       products_processed, labels_processed, access_points_processed,
       duration, started_at, finished_at, error_message
FROM esl.sync_state
ORDER BY finished_at DESC
LIMIT 10;
```

Query per-store sync history:

```sql
SELECT store_id, sync_status, products_processed,
       labels_processed, access_points_processed,
       synced_at, error_message
FROM esl.store_sync_state
WHERE pipeline_name = 'esl-orchestrator-pp'
ORDER BY synced_at DESC
LIMIT 20;
```

### Viewing Migration Status

Check Flyway migration history from the migration job logs:

```bash
kubectl logs job/orchestrator-esl-datapipeline-db-migrations \
  -n instore-esl-orchestrator-pp
```

Or query the Flyway history table directly:

```sql
SELECT version, description, installed_on, success
FROM flyway_schema_history
ORDER BY installed_rank DESC
LIMIT 10;
```

### Checking Failed Records

Query the error tracking table for records that failed during sync:

```sql
SELECT table_name, record_id, sync_mode,
       error_type, error_message, pg_error_code,
       created_at
FROM esl.records_with_errors
ORDER BY created_at DESC
LIMIT 20;
```

## Troubleshooting

### Pipeline Job Fails Immediately

**Symptom:** CronJob pod enters `Error` state and does not retry.

**Possible causes:**

1. **Configuration error** — invalid YAML in the ConfigMap. Check the pod logs:
   ```bash
   kubectl logs <pod-name> -n <namespace>
   ```
2. **Secret not available** — ExternalSecret has not synced. Check the ExternalSecret status:
   ```bash
   kubectl get externalsecret -n <namespace>
   ```
3. **Database unreachable** — network policy or database is down. Verify connectivity.

### Migration Job Blocks Deployment

**Symptom:** ArgoCD sync stuck in PreSync phase.

**Cause:** The Flyway migration job failed (backoff limit is 0 — it does not retry).

**Resolution:**

1. Check the migration job logs for the SQL error
2. Fix the migration in the database repository
3. Push a new image tag
4. Update the image tag in the values file
5. ArgoCD will re-run the PreSync job with the new image

### DataFetch API Returns 503

**Symptom:** Readiness probe fails, API removed from Service endpoints.

**Cause:** Database connectivity lost (readiness probe pings the database with a 2-second timeout).

**Resolution:**

1. Verify the database is accessible from the namespace
2. Check network policy egress rules
3. Check ExternalSecret for correct database credentials
4. Once connectivity is restored, the readiness probe will automatically pass and the pod will be added back to the Service endpoints

### Incremental Sync Fetches Too Much Data

**Symptom:** Pipeline run takes longer than expected despite incremental mode.

**Possible causes:**

1. **Large lookback window** — the `lookback_window` setting adds a safety margin. If set too high (e.g., `24h`), it will re-fetch more data than necessary.
2. **First run for new stores** — newly added stores always do a full sync. Check the store filter to ensure only intended stores are included.
3. **Previous run failed** — if the last run for a store failed, the next run falls back to the last *successful* run's timestamp (or full sync if none exists).

### Pipeline Processes Zero Records

**Symptom:** Sync state shows 0 records processed.

**Possible causes:**

1. **Store filter mismatch** — the configured `filter_stores` or `filter_retail_chains` don't match any stores in the Vusion API
2. **API credentials invalid** — check the connector secrets. The pipeline logs will show authentication errors.
3. **No modified records** — in incremental mode, if no records have been modified since the last sync, 0 is expected behaviour
