# Shared Logger + Timestamp Standardization (DRAFT, staged)

**Status:** DRAFT. Scoped and decisions locked 2026-04-17. Execution not yet started. Resume by starting PR 1.

**Origin:** Began as a timestamp-standardization audit across `datapipeline`, `event-publisher`, `datafetch`, and the `k8s` helm chart. Expanded to include a shared logger pre-task after the audit found all three services use `zap` independently — the encoder fix and `TZ` env delivery are naturally centralized.

## Contract rules (main task)

1. Outbound payloads (Solace messages, outbox JSON) = UTC with `Z` suffix.
2. Outbound query params to third-party APIs = UTC.
3. Logs = ISO8601 with explicit offset (`+00:00` / `+01:00`). `TZ` env on the pod supplies the zone.
4. Postgres columns = `TIMESTAMPTZ` (already conforms; not in scope).
5. `datafetch` REST response = machine-to-machine → UTC `Z` (status quo, no change).

## Audit findings

**Non-compliant (to fix):**

- `event-publisher/cmd/eventpublisher/main.go:47` — bare `zap.NewProductionConfig()` emits Unix epoch floats. TZ env is currently a no-op because of this.
- `datafetch/cmd/datafetch/main.go:209` (prod), `:211` (dev) — same issue for both configs.
- `datapipeline/internal/connector/vusion/vusion.go:199` — `modifiedAt.Format(time.RFC3339)` without `.UTC()`. Hardening fix (not a live bug — Vusion Manager sends `Z`, but VLink's OAS example uses `+00:00`, so this is latent).
- k8s helm: `helm/templates/datafetch-api.yaml` and `helm/templates/eventpublisher-deployment.yaml` have no `TZ` env; `datapipeline-cronjob.yaml:307-308` is the reference pattern. Values files (`clusters/cluster-dev/values-dev.yaml`, `…-pp/values-pp.yaml`, `…-production/values-prd.yaml`) need `timeZone: "Europe/Lisbon"` under both `dataFetch` and `eventPublisher` — 6 additions.

**Already compliant (don't touch):**

- `datapipeline/internal/logger/logger.go:21` — `zapcore.TimeEncoderOfLayout("2006-01-02T15:04:05.000Z07:00")`.
- `datapipeline/internal/sink/postgres/cdc.go:278,285` — `.UTC().Format(time.RFC3339Nano)`.
- `datapipeline/internal/connector/vusion/vlink/client.go:272` — `since.UTC().Format(time.RFC3339)`.
- `datapipeline/internal/sink/postgres/cdc.go:507-541` — outbox `INSERT` via pgx `time.Time` → `TIMESTAMPTZ`.
- `datafetch/internal/adapters/postgres/repository.go:130` — `t.UTC()` on every scanned `time.Time` before response.
- `event-publisher/internal/transform/transform.go:65` — `now.UTC().Format(time.RFC3339)` → Solace `send_date`.

## Pre-task: shared `common/logger` package

### Decisions (locked 2026-04-17)

- **API shape**: return `*zap.Logger` (no abstraction layer). Services keep typed zap fields at call sites.
- **`InstanceFields []zap.Field`**: typed, not `map[string]string`. Attached to every log line.
- **UUID → `run_id`**: rename for clarity. `datapipeline` passes `zap.String("run_id", uuid.New().String())`. `event-publisher` and `datafetch` pass nil `InstanceFields` (Loki stream labels cover service/version/commit).
- **Layout**: `TimeLayout = "2006-01-02T15:04:05.000Z07:00"` exported constant from `common/logger`.
- **No Loki dashboards key off `uuid` today** (confirmed with user); rename is safe.

### API sketch

```go
package logger

import "go.uber.org/zap"

const TimeLayout = "2006-01-02T15:04:05.000Z07:00"

type Config struct {
    Env            string       // "production" | "development"
    Level          string       // "debug" | "info" | "warn" | "error"
    InstanceFields []zap.Field  // attached to every log line; nil for none
}

func New(cfg Config) (*zap.Logger, error)
```

### PR split

1. **PR 1 — `common/logger` package** (new, in `common/` repo)
   - New files: `common/logger/logger.go`, `common/logger/logger_test.go`.
   - Add `go.uber.org/zap` to `common/go.mod`.
   - Tests: prod JSON vs dev console, EncodeTime layout verification, invalid level error, `InstanceFields` applied.
   - Verify: `cd common && go test ./... && go build ./...`.

2. **PR 2 — event-publisher** (light)
   - `cmd/eventpublisher/main.go:47` — replace `zap.NewProductionConfig()` block with `logger.New(logger.Config{Env: "production", Level: cfg.Log.Level})`.
   - Bump `common` module in `go.mod`.
   - Verify: `make lint && go test -tags=integration ./...`.

3. **PR 3 — datafetch** (light)
   - `cmd/datafetch/main.go:201-218` — replace `newLogger` body with `logger.New(logger.Config{Env: appEnv, Level: logLevel})`. Covers prod + dev in one call.
   - Bump `common`.
   - Verify: `make fmt && make lint && make test && make build`.

4. **PR 4 — datapipeline** (heavy — ~1-2 days)
   - `cmd/eslorchestrator/main.go` — construct via `logger.New(Config{Env: "production", Level: "info", InstanceFields: []zap.Field{zap.String("run_id", uuid.New().String())}})`.
   - Delete `internal/logger/logger.go` and `internal/logger/logger_test.go`.
   - Migrate **387 log call sites** across **68 files** + **95 `With*`/`WithField` sites** from SugaredLogger to structured. Translation rules:
     - `l.Info("msg")` → unchanged.
     - `l.Infof("fmt %s", x)` → `l.Info("fmt", zap.String("x", x))` (choose field names; lowercase snake_case to match repo convention).
     - `l.WithField("k", v).Info("msg")` → `l.Info("msg", zap.<Type>("k", v))`.
     - `l.Errorf("failed: %s", err)` → `l.Error("failed", zap.Error(err))`.
   - Update package-level types: every package taking `*logger.Logger` now takes `*zap.Logger`.
   - Verify: `go build ./... && go test ./...`. Do NOT run `make test-e2e` (gated by CLAUDE.md).
   - Risk: field-name drift across files; lost context where formatted messages embedded values. Mitigation: final-pass review for stray `%s` / `%d` in log messages.

## Main task (after pre-task lands)

1. **Fix `datapipeline/internal/connector/vusion/vusion.go:199`** — change `modifiedAt.Format(time.RFC3339)` to `modifiedAt.UTC().Format(time.RFC3339)`. One-line hardening change.
2. **Add `TZ=Europe/Lisbon` to helm** — edit `k8s/helm/templates/datafetch-api.yaml` (insert after `TMPDIR` env, line 227-228) and `helm/templates/eventpublisher-deployment.yaml` (insert as first env, line 207-208). Both use `{{ $<x>.timeZone | default "UTC" | quote }}` pattern.
3. **Add `timeZone: "Europe/Lisbon"`** under `dataFetch` and `eventPublisher` sections in each cluster values file (dev, pp, prd).
4. **Verify** with `helm lint` across all three cluster environments (per k8s/CLAUDE.md).

The main task is small (~5 files) because PR 1–4 centralize the encoder in `common/logger`.

## Rollout order per service

Go-repo change first, helm `TZ` env second. Intermediate state (new encoder, no TZ env yet) produces `Z`-suffixed logs because pod effective zone is UTC without TZ — still compliant because rule 3's "never bare Z when TZ=Europe/Lisbon" only bites once TZ is set.

## Resume point

Start PR 1. All file paths and line numbers above were verified 2026-04-17 — re-confirm before editing in case anything moved. Existing tasks `#2`, `#3`, `#4`, `#5` in the task tracker correspond to this plan; when resuming, check their state first.
