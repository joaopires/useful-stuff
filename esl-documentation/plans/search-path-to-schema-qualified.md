# Migration Plan: PostgreSQL `search_path` → Schema-Qualified Queries

Status: Draft
Audience: ESL platform engineers
Scope: `common`, `datafetch`, `datapipeline`, `event-publisher`, `database`

---

## 1. Context and Decision

### What broke

`datafetch` fails to boot in TST:

```
FATAL: unsupported startup parameter: search_path (SQLSTATE 08P01)
```

The TST Postgres sits behind pgBouncer configured in **transaction pooling mode**. In that mode pgBouncer refuses any client connection whose `StartupMessage` carries unknown runtime parameters, and `search_path` is not on its implicit allow-list.

The offending line lives in the shared library `common`:

- `common/postgres/pool.go:123` — `poolCfg.ConnConfig.RuntimeParams["search_path"] = cfg.Schema`

Every service that imports `common/postgres` (currently `datafetch`, `datapipeline`, `event-publisher`) inherits this StartupMessage parameter and cannot connect through pgBouncer-in-transaction-mode.

### Why we are not fixing it at pgBouncer

The DBA rejected adding `search_path` to `ignore_startup_parameters` on pgBouncer. Reason: `ignore_startup_parameters` silently drops the value. If any copy of a table (or, more likely, a view / sequence / function with the same name) ever lands in `public`, every read and every write silently targets the wrong schema with no error surfaced to the app. That is a data-correctness risk the team is not willing to carry for the sake of a convenience parameter.

### The decision

1. Every Go SQL site fully schema-qualifies the objects it touches — tables, sequences, and custom functions.
2. `common` owns the one canonical helper for building a qualified identifier; consumers never hand-roll `"esl"."stores"` and they never call `pgx.Identifier{schema, name}.Sanitize()` on their own.
3. `common/postgres/pool.go` stops setting `search_path` on the connection. Connections run with the Postgres / role default search_path; the app does not rely on it for correctness.
4. Flyway migration `V1.0.0.13__configure_pgbouncer_compat.sql` is rewritten to fix two latent bugs discovered while auditing the pgBouncer story. See §5.

Removing `search_path` from `RuntimeParams` is the final, breaking step. It must not ship in `common` until every consumer — in every environment that runs the new `common` version — already issues only qualified queries.

---

## 2. Inventory of SQL Sites

### 2.1 `common` (shared library)

The library does not itself issue business SQL. It carries three touch-points:

| File | Location | Role |
|------|----------|------|
| `common/postgres/pool.go` | line 123 | **Only source of `search_path` injection.** Remove in final step. |
| `common/postgres/pool_integration_test.go` | `TestNewPoolDefaultSchema`, `TestNewPoolCustomSchema` | Run `SHOW search_path` and create unqualified tables expecting them to land in the configured schema. Will fail the day `pool.go:123` is deleted. Rewrite to target the new helper. |
| `common/README.md` | line 45 | `Schema` field documented as "Sets `search_path` on every connection". Update wording. |
| `common/postgres/pool_test.go` | `TestSetDefaults`, `TestSetDefaults_PreservesExplicitValues` | Assert `PoolConfig.Schema == "public"` / custom value. Keep — the field stays, its **effect** changes. |

`common/entity/keys.go` exports `EntityType` and `ConflictKeys` — both bare column-name primitives with no schema semantics. They should compose cleanly with the new helper; no change.

`common/event`, `common/logger`, `common/config-workflows` — schema-agnostic; no change.

### 2.2 `datafetch`

Production-path SQL:

| File:line | Pattern | Qualified today? |
|-----------|---------|------------------|
| `internal/adapters/postgres/repository.go:54` | `tableExpr := pgx.Identifier{params.EntityName}.Sanitize()` → used in FROM at :103 and :145 | **No.** Bare `"stores"`, `"products"`, `"labels"`, `"access_points"`. |
| `internal/adapters/postgres/repository.go:59,64,165` | `pgx.Identifier{col}.Sanitize()` for columns / order-by / WHERE | No change needed — column identifiers do not require a schema. |
| `internal/adapters/postgres/schema_validator.go:61–65` | `SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2` | **Yes.** Schema passed as a bound parameter; `information_schema` is a catalog namespace, not search_path-resolved. No change. |

Tests that simulate the unqualified world and will break:

- `internal/adapters/postgres/repository_test.go:114–141` — `CREATE TABLE users / products / events` unqualified in a testcontainer.
- `internal/adapters/postgres/schema_validator_test.go:74–81, 144` — `CREATE TABLE items / other` unqualified.

Wiring:

- `internal/config/config.go:67` — `DBSchema: getEnv("DB_SCHEMA", "public")`.
- `cmd/datafetch/main.go:49–64` — `commonpg.NewPool(..., PoolConfig{Schema: cfg.DBSchema, ...})`.
- `cmd/datafetch/main.go:124` — `postgres.NewSchemaValidator(pool, cfg.DBSchema, logger)` — validator already receives schema explicitly.
- **Repository does not currently receive the schema.** Must be threaded through.

Environment values:

- `docker-compose.yaml`: `DB_SCHEMA=public` (local dev container).
- `k8s/helm/templates/datafetch-api.yaml:287–293`: `DB_SCHEMA` sourced from a `secretKeyRef` (`DbSchema`). The effective production value is `esl`.

Tables referenced (from `internal/config/entities.yaml`): `stores`, `labels`, `access_points`, `products`. These are entity-typed and driven by config; qualification must flow through the same config.

Prometheus middleware (`internal/adapters/http/metrics.go`) does not issue SQL; `/ready` uses `pool.Ping()`. No extra sites.

### 2.3 `datapipeline`

This repo has its **own** thin wrapper on top of `common`: `internal/postgres/connection.go` defines `ConnectionConfig` which embeds most `commonpg.PoolConfig` fields (including `Schema`) and maps to it in `PoolConfig()`. This is an extra consumer the plan must account for in addition to the three top-level services.

Production-path SQL — all unqualified, all using `fmt.Sprintf` with a bare table name:

| File:line | Pattern | Table |
|-----------|---------|-------|
| `internal/sink/postgres/errors.go:138–141` | `INSERT INTO records_with_errors (...) VALUES (...)` | `records_with_errors` (hardcoded) |
| `internal/sink/postgres/query.go:148` | `INSERT INTO %s (...) VALUES (...) ON CONFLICT (...) DO UPDATE SET ...` | Any configured record type (`products`, `labels`, `stores`, `access_points`) |
| `internal/sink/postgres/cdc.go:249–255` | `SELECT %s FROM %s WHERE (%s) IN (%s)` | Same set as above (CDC baseline fetch) |
| `internal/sink/postgres/cdc.go:534–539` | `INSERT INTO event_outbox (...) VALUES %s` | `event_outbox` (hardcoded) |
| `internal/state/postgres/postgres_state.go:105` | `INSERT INTO %s (...) RETURNING id, finished_at` | `sync_state` (via `s.tableName`) |
| `internal/state/postgres/postgres_state.go:159` | `SELECT DISTINCT ON (...) FROM %s s JOIN ...` | `store_sync_state` (via `s.storeTableName`) |
| `internal/state/postgres/postgres_state.go:213` | `INSERT INTO %s (...) RETURNING id` | `store_sync_state` |
| `internal/state/postgres/postgres_state.go:250` | Batched `INSERT INTO %s (...) RETURNING id` via `pgx.Batch` | `store_sync_state` |

Tests with inline unqualified SQL (testcontainer-backed integration; will need updates once `search_path` is gone):

- `internal/sink/postgres/postgres_integration_test.go:138–176` — `CREATE TABLE`, `SELECT COUNT(*)` bare.
- `internal/sink/postgres/cdc_integration_test.go:54–148` — `cdcEntityTableSQL()` helper, TRUNCATE, etc. bare.
- `internal/sink/postgres/error_handling_integration_test.go` — queries `records_with_errors` bare.
- `internal/state/postgres/postgres_state_test.go:25, 77, 95, 113` — fixtures use `Schema: "public"`.
- `internal/state/postgres/postgres_integration_test.go` — direct `sql.Open` connection; queries bare tables.

Out-of-scope confirmed:

- `godog-e2e/domain/db.go` opens a pgx stdlib pool but does not set `search_path` and the step definitions do **not** issue raw SQL against business tables (grep for FROM/INSERT/UPDATE/DELETE under `godog-e2e/` returns nothing outside of `.feature` scenario text). Leave it as-is; flag for audit during rollout in case step packs change.

Config surfaces where `Schema` lives but is currently read-and-dropped in query construction:

- `internal/postgres/connection.go:13–29` — `ConnectionConfig.Schema`, used only to pass through to `commonpg.PoolConfig`.
- `internal/sink/postgres/config.go` — sink config embeds `ConnectionConfig`.
- `internal/state/postgres/postgres_state.go` — state store config embeds `ConnectionConfig`.

Environment values: `config.yaml` (repo) does not explicitly set `schema`; effective value comes from env / k8s secret. In all ESL environments the value is `esl` (or `public` in local docker-compose fixtures).

### 2.4 `event-publisher`

Production-path SQL (all four constants live in `internal/outbox/repository.go`):

| File:line | Constant | Body | Schema? |
|-----------|----------|------|---------|
| `repository.go:62` | `hasPendingQuery` | `SELECT EXISTS(SELECT 1 FROM event_outbox WHERE status = $1)` | No |
| `repository.go:73–80` | `fetchPendingQuery` | `SELECT ... FROM event_outbox WHERE status = $1 ORDER BY occurred_at LIMIT $2 FOR UPDATE SKIP LOCKED` | No |
| `repository.go:141–143` | `markDeliveredBatchQuery` | `UPDATE event_outbox SET status = $1, delivered_at = $2 WHERE id = ANY($3)` | No |
| `repository.go:163–165` | `markFailedBatchQuery` | `UPDATE event_outbox SET status = $1 WHERE id = ANY($2)` | No |

Integration tests that create / tear down / read `event_outbox` unqualified:

- `internal/relay/relay_integration_test.go:54–64, 77, 96, 167`.

Wiring:

- `internal/config/config.go:38–39` — `Schema` field with comment `// schema for search_path (set at pool level)`. Comment will be misleading post-migration.
- `config.yaml:8` — `schema: esl   # schema for search_path (set at pool level)`. Same comment.
- `cmd/eventpublisher/main.go:66` — `postgres.NewPool(ctx, poolCfg)` — inherits the RuntimeParam setter.
- `internal/health/health.go:83` — `db.Ping()` only. No SQL body.

### 2.5 `database` (Flyway)

20 migrations, `V1.0.0.01` … `V1.0.0.20`. Audit result: **every table, index, foreign key, trigger, and function body is already fully schema-qualified with `esl.`**. Migrations do not rely on `search_path`. Confirmed by grepping all of `sql/` for bare `FROM`, `INTO`, `REFERENCES`, and for the string `search_path` (returns zero matches).

Objects relevant to the risk section:

- Tables (all under `esl.`): `stores`, `access_points`, `products`, `labels`, `records_with_errors`, `sync_state`, `store_sync_state`, `event_outbox`.
- Sequences: three implicit (SERIAL/BIGSERIAL on `records_with_errors.id`, `sync_state.id`, `store_sync_state.id`). Default expressions are `nextval('esl...seq'::regclass)` — Postgres stores the sequence OID at DDL time, so DEFAULT resolution survives search_path removal.
- Functions (all `esl.`): `trg_sync_state_retention()`, `trg_store_sync_state_retention()`, `cleanup_delivered_events()`. Bodies already reference `esl.sync_state`, `esl.store_sync_state`, `esl.event_outbox` explicitly.
- Triggers: two, on `esl.sync_state` and `esl.store_sync_state`.
- Extension: `pg_trgm` in `public` (pg default). Used only in GIN index definitions via `gin_trgm_ops`, which is resolved by operator class name — not by search_path.

Flyway connects as `esluser` in every environment we can see; apps also connect as `esluser`. **Flyway and app share the same role today.** That masks bug #1 in V13 but doesn't fix it.

### 2.6 Summary count

| Scope | Non-test SQL sites needing qualification |
|-------|-----------------------------------------|
| `common` | 0 (library does not issue SQL; one RuntimeParam line to remove) |
| `datafetch` | 2 (both in `repository.go`) |
| `datapipeline` | 8 (4 sink, 4 state) |
| `event-publisher` | 4 (all in `outbox/repository.go`) |
| `database` | 0 (already qualified; 1 migration to rewrite for unrelated bugs) |
| **Total** | **14 production SQL sites + integration fixtures + 1 Flyway migration** |

---

## 3. `common` API Shape

### 3.1 Options considered

1. **Free function** — `commonpg.Qualify(schema, table string) string` returns `"esl"."event_outbox"`.
2. **Struct value** — `commonpg.Table{Schema, Name string}.Sanitize() string`.
3. **Schema builder** — `s := commonpg.NewSchema("esl"); s.Table("event_outbox")` returns a ready-to-inject qualified identifier.
4. **pgx.Identifier passthrough** — `commonpg.Identifier(schema, table) pgx.Identifier` and let the caller `.Sanitize()`.

### 3.2 Recommendation — combine builder + convenience free function

Export both:

```
// postgres/identifier.go (new file)

package postgres

import "github.com/jackc/pgx/v5"

// Schema binds a fixed schema name so that call sites only carry the table
// name. Construct once per pool/component and inject alongside *pgxpool.Pool.
type Schema struct{ name string }

func NewSchema(name string) Schema { return Schema{name: name} }

// Name returns the raw (unquoted) schema name, useful for pass-through to
// queries that bind the schema as a parameter (e.g. information_schema).
func (s Schema) Name() string { return s.name }

// Table returns a schema-qualified, double-quoted identifier safe to embed
// directly in a SQL string, e.g. `"esl"."event_outbox"`.
func (s Schema) Table(name string) string {
    return pgx.Identifier{s.name, name}.Sanitize()
}

// Qualify is a stateless convenience for call sites that don't carry a
// Schema (e.g. one-off admin tooling). Prefer NewSchema + Table in services.
func Qualify(schema, table string) string {
    return pgx.Identifier{schema, table}.Sanitize()
}
```

### 3.3 Why this shape

- **One arg at call sites.** In service code the schema is fixed for the life of the pool; repeating it at every call site is noise.
- **Injectable alongside the pool.** `Repository` constructors already take `*pgxpool.Pool`; adding a `commonpg.Schema` makes the schema binding explicit and swappable in tests.
- **Composes with pgx.Identifier.** Internally delegates to `pgx.Identifier.Sanitize()`, so the quoting rules and escaping behaviour match what the code already trusts elsewhere.
- **Survives placeholders.** Identifiers cannot be parameterised; the helper returns a ready-to-interpolate string, compatible with `fmt.Sprintf("SELECT ... FROM %s WHERE id = $1", s.Table("event_outbox"))`.
- **Keeps `Name()` accessible** for the single remaining case where the *unquoted* schema name is a bound parameter (e.g. `datafetch`'s `schema_validator.go` WHERE clause `table_schema = $1`). Consumers do not need to reach into the struct.
- **Zero allocation beyond Sanitize.** No builder chains, no closures.

### 3.4 Explicit non-features

- No caching / interning. `Sanitize` is cheap; memoising would complicate tests and produce a parallel correctness surface.
- No `Column(name) string` helper. Bare column identifiers do not need the schema; `pgx.Identifier` already covers them where dynamic. Introducing a Column helper would only push services towards over-quoting.
- No multi-schema builder. No ESL service currently talks to more than one schema. If that changes later, `NewSchema` is cheap to spin up per-schema.
- `PoolConfig.Schema` stays on the struct. It remains the single source of truth for "which schema this pool targets" and is the value consumers pass to `NewSchema`. Its *effect* on the pool changes — it no longer sets the RuntimeParam — but the field stays, documented as "The schema consumers should bind to `commonpg.NewSchema`; the pool itself does not enforce it".

### 3.5 Versioning implication

`common` uses pseudo-versions today; consumers pin `v0.1.1-0.20260420142405-805206ed18d5`. The helper is additive and can ship as a non-breaking minor bump (still in `v0.1.x`). The RuntimeParam removal, however, is observable behaviour change — any consumer that did not migrate will silently lose schema scoping. Bundle that change with a **`v0.2.0` tag** and a release note that explicitly names the break. No tagged SemVer contract exists before v0.1.0, so v0.2.0 is uncontroversial.

---

## 4. Ordered Rollout

The core constraint: **removing `RuntimeParams["search_path"]` in `common` must be the last step**, and must not be consumed by any service running in any environment (including CI) until that service has switched every SQL site to qualified identifiers.

### PR sequence

| # | Repo | PR summary | Ship independently? |
|---|------|------------|---------------------|
| 1 | `common` | Add `postgres.Schema` + `postgres.Qualify`, add unit tests for the helper, keep `RuntimeParams["search_path"]` intact. Release as `v0.1.x` (minor). | Yes — purely additive. |
| 2 | `datafetch` | Bump `common` to the tag from PR #1; thread `commonpg.Schema` through repository / wiring; qualify both FROM sites; update `repository_test.go` and `schema_validator_test.go` fixtures to create qualified tables. | Yes — after PR #1 merges. |
| 3 | `event-publisher` | Bump `common`; rewrite four constants in `outbox/repository.go` to interpolate `commonpg.Schema.Table("event_outbox")`; update `relay_integration_test.go` fixtures; update config comment wording. | Yes — after PR #1. |
| 4 | `datapipeline` | Bump `common`; qualify the 8 sink/state SQL sites; have `ConnectionConfig` expose a `commonpg.Schema` value next to the existing `Schema string` field (or derive one at pool-construction time); update integration test fixtures. | Yes — after PR #1. |
| 5 | `database` | V1.0.0.13 rewrite (see §5). Independent of the Go changes; can ship in parallel. | Yes. |
| 6 | `common` | **Breaking:** delete `poolCfg.ConnConfig.RuntimeParams["search_path"] = cfg.Schema` from `pool.go:123`. Rewrite `pool_integration_test.go` so the two `TestNewPool*Schema` tests no longer run `SHOW search_path`; instead they assert the new helper produces expected strings and that a qualified insert + select round-trips through the pool. Update `README.md:45` and the comment in `PoolConfig.Schema`. Release as `v0.2.0`. | **No** — must merge only after PRs #2, #3, #4 have been deployed to DEV/QA/TST/PROD. |
| 7 | Each service | Bump `common` to `v0.2.0`. Stagger per env (see §6). | Yes, independently per service, as long as ordering within each env is: deploy → validate → next env. |

PRs #2, #3, #4 pin the same intermediate `common` version from PR #1. The fact that `common/postgres/pool.go:123` still sets `search_path` at that point is fine — pgBouncer in TST still rejects it, but:

- DEV and integration tests use direct Postgres (no pgBouncer), so CI stays green.
- **TST deploys remain blocked until PR #6 + PR #7 land.** That blockage is the reason for the work; don't pretend otherwise.

### Alternative ordering considered and rejected

"Do PR #6 first, then migrate." — Rejected. It would unblock the TST deploy for an hour and then produce silently-wrong behaviour (reads/writes against `public` for any bare reference) for the remainder of the migration. The DBA's objection to `ignore_startup_parameters` applies equally here: unqualified + no search_path = land in `public`.

"Ship PR #6 and #7 as one PR pair per service, merging them together per service." — Tempting but breaks the `common` module shape: #6 must be a single tagged release of `common`, not three. A per-service merge also means any service lagging blocks all others from adopting `v0.2.0`.

---

## 5. V1.0.0.13 Rewrite

### 5.1 Current content

```sql
DO $$
BEGIN
  EXECUTE format(
    'ALTER ROLE %I SET extra_float_digits = 3',
    current_user
  );
  EXECUTE format(
    'ALTER ROLE %I SET statement_timeout = ''30s''',
    current_user
  );
END;
$$;
```

Comment header states the migration exists for **PostgreSQL JDBC driver 42.x compatibility** behind pgBouncer — the JDBC driver sends `extra_float_digits` and `statement_timeout` as startup parameters, and pgBouncer is configured with `ignore_startup_parameters = extra_float_digits,statement_timeout`. This migration compensates for the stripped values by setting them at the role level.

### 5.2 Known bugs

**Bug 1 (active): `statement_timeout = '30s'` at the role level.** `current_user` at V13 execution time resolves to the Flyway role, which is the role that runs every future Flyway migration. The next `CREATE INDEX CONCURRENTLY` on `esl.labels` — at production scale ~7.5M rows — silently inherits the 30s cap and fails. pgx-based Go services that want query timeouts enforce them via `context.WithTimeout`; `statement_timeout` does not belong at role level on the Flyway role (where it breaks DDL), nor on the app role (where contexts already do the job), nor anywhere else in this platform.

**Bug 2 (latent): `current_user` targeting is brittle under role splits.** For `extra_float_digits = 3` the targeting is actually correct — Flyway (the pgJDBC 42.x consumer that V13 exists for) runs as `current_user` at migration time, so V13's `extra_float_digits` line landed exactly where it should. The fragility is only that if any future environment runs migrations under a different role than today's `esluser`, V13's `extra_float_digits` default silently stops following Flyway. Low exposure today (Flyway and apps share `esluser` in every env we can see); called out because V21's reset must target the *same* role V13 wrote to.

### 5.3 Proposed rewrite — add V21 that undoes the `statement_timeout` footgun

Flyway migrations are immutable once deployed (`validateOnMigrate=true`). V13 has been applied; we must not edit it. Add a new migration that removes only the role-level `statement_timeout`. Leave `extra_float_digits = 3` exactly where V13 put it — that line is V13's reason for existing: Flyway's pgJDBC driver sends `extra_float_digits=3` in the StartupMessage, pgBouncer strips it, and the role-level default restores it server-side. Removing it would re-break Flyway behind pgBouncer.

New migration `sql/V1.0.0.21__fix_role_statement_timeout.sql`:

```sql
-- Fixes V1.0.0.13's second role-level ALTER.
--
-- V13 applied statement_timeout = '30s' to whichever role runs Flyway
-- (current_user at V13 time = the Flyway role). That same role also runs
-- every future DDL migration; once a migration needs longer than 30s —
-- a CREATE INDEX CONCURRENTLY on esl.labels at production scale, say —
-- it fails silently at the server cap.
--
-- extra_float_digits stays as V13 left it: Flyway's pgJDBC driver sends
-- extra_float_digits at connect time, pgBouncer strips it, and the role
-- default restores it server-side. That line is V13's reason for existing
-- and must not be reset here.
--
-- Query-level timeouts for the Go services are enforced via context
-- deadlines in application code; no role-level cap for that purpose.

DO $$
BEGIN
  EXECUTE format('ALTER ROLE %I RESET statement_timeout', current_user);
END;
$$;
```

Notes:

- `current_user` is used again on purpose — V21 must reset `statement_timeout` on the *same* role V13 set it on. In every ESL environment today that role is `esluser` (shared with the apps); the `DO $$ ... current_user ...` form keeps V21 correct as long as Flyway runs V21 from the same role that ran V13.
- If the team later splits Flyway and app roles, add a targeted `ALTER ROLE flyway_user RESET statement_timeout` in a follow-up migration once the split is in place. No need to anticipate now.
- Before shipping V21, audit `flyway_schema_history` for any past migration that may have silently hit the 30s cap — see §8.2.

### 5.4 `statement_timeout` — where does it belong now?

V13's `statement_timeout = '30s'` looks like a copy-paste of a JDBC-compat recipe that bundles both knobs together. It needs a home or no home; no role-level home is tenable. Four options for a runtime query cap:

1. **Any role-level `ALTER ROLE ... SET statement_timeout`.** **Rejected.** It either breaks Flyway (if on the Flyway role) or duplicates what `context.Context` already enforces in the Go code (if on the app role), and it is invisible to reviewers.
2. **Per-application set at connect time** via pgx `RuntimeParams["statement_timeout"] = "30s"`. pgBouncer transaction mode rejects that the same way it rejects `search_path`. **Rejected.**
3. **pgx `AfterConnect` hook** issuing `SET statement_timeout = '30s'` on every new backend the pool opens. pgBouncer in transaction mode preserves session-level `SET` within a backend, so this survives. Defensible if the team wants a hard server-side cap.
4. **Do nothing server-side; enforce via `context.Context` deadlines in the Go code.** pgx honours context cancellation at the query level; the services already pass contexts through.

**Recommendation:** option 4 is already the de facto contract in the Go services. Make it explicit in `common/postgres/pool.go`'s doc comment that per-query timeouts must come from `context.Context`. Drop the `statement_timeout` ambition entirely from the Flyway / role layer. If defence in depth is wanted later, option 3 is additive and can land separately; don't bundle with this migration.

### 5.5 Should V21 re-introduce `search_path` as a role default?

Both sides:

**For.** Defence in depth. If any future Go code slips an unqualified reference through review, `ALTER ROLE esluser SET search_path = 'esl', 'public'` means it still resolves to `esl.X`. pgBouncer is happy because the value lives server-side, not on the StartupMessage. And it directly answers the DBA's concern about "silent drop" — the value is not dropped, it is set, visible, and auditable with `\drds esluser` in psql.

**Against.** Every other element of this plan explicitly moves responsibility into the code. Re-adding a role-level default reintroduces the "works on my machine but not in a newly-created role" fragility that the migration was supposed to eliminate, and it splits the mental model: some envs rely on it, some don't, and tests can't easily assert the absence of unqualified references because the safety net masks them. It also means that if the ESL schema ever gets renamed or split, the fallback is another place that has to change in lockstep.

**Recommendation:** add it — but scoped and documented as a *defence-in-depth safety net only*, not load-bearing. The CI check described in §6.4 is the primary guard; the role default is the backstop. If adopted, introduce a Flyway placeholder for the app role (the role the Go services connect as, not Flyway's role) and extend V21:

```
# flyway.conf
flyway.placeholders.appRole=esluser
```

```sql
-- Defence-in-depth: if a future regression slips an unqualified reference,
-- route it to esl rather than public. Application code must still qualify
-- every reference explicitly; this is a safety net, not a contract.
ALTER ROLE ${appRole} SET search_path = 'esl', 'public';
```

Revisit in 6 months: if the CI check has caught nothing and no incident has relied on the backstop, drop the line and remove the placeholder.

Sanity check: putting `'esl', 'public'` in that order, rather than `'public', 'esl'`, matters. If the fallback ever gets used, it must route to `esl` first.

---

## 6. Per-Repo Change List and Test Strategy

### 6.1 `common`

**PR #1 (additive):**

- New file: `postgres/identifier.go` — `Schema`, `NewSchema`, `Schema.Table`, `Schema.Name`, `Qualify`.
- New file: `postgres/identifier_test.go` — table-driven tests covering quoting edge cases (names with uppercase, names containing a quote, empty schema, empty table — should panic like `pgx.Identifier` does), and that `Qualify` and `Schema.Table` return equal output for the same inputs.
- `README.md`: add a "Schema qualification" subsection with a worked example.
- Tag as `v0.1.x`.

**PR #6 (breaking):**

- `postgres/pool.go`: delete line 123 (`poolCfg.ConnConfig.RuntimeParams["search_path"] = cfg.Schema`).
- `postgres/pool.go`: update the doc-comment on `PoolConfig.Schema` to: "Schema that consumers should pass to `NewSchema`. The pool does not set `search_path`; qualify all table references explicitly."
- `postgres/pool_integration_test.go`: delete the two `SHOW search_path` assertions. Replace `TestNewPool*Schema` with a single `TestNewPoolRoundTripsQualifiedTable` that creates `CREATE SCHEMA IF NOT EXISTS test_xyz`, then `CREATE TABLE test_xyz.marker (...)`, inserts via `Qualify("test_xyz", "marker")`, reads back via `Schema.Table`, and drops the schema.
- `README.md:45`: rewrite the `Schema` field description.
- Tag as `v0.2.0`.

**Integration test harness:** already uses testcontainers-postgres. No pgBouncer in front; do not add one here. The pgBouncer compatibility check lives in `datafetch` (§6.4).

### 6.2 `datafetch`

**Files touched:**

- `cmd/datafetch/main.go` — construct `schema := commonpg.NewSchema(cfg.DBSchema)` after the pool, inject into `postgres.NewPostgresRepository(pool, schema)` (new signature).
- `internal/adapters/postgres/repository.go` —
  - Struct gets a `schema commonpg.Schema` field.
  - Constructor `NewPostgresRepository` takes it.
  - `FetchEntityData` replaces `tableExpr := pgx.Identifier{params.EntityName}.Sanitize()` with `tableExpr := r.schema.Table(params.EntityName)`.
  - The column `Identifier` calls at :59, :64, :165 stay (columns are not schema-qualified).
- `internal/adapters/postgres/schema_validator.go` — no behavioural change. Optionally take `commonpg.Schema` instead of a bare `string` for API symmetry; call `.Name()` where the parameter is bound.
- `internal/adapters/postgres/repository_test.go` (lines 114–141) — either (a) wrap each `CREATE TABLE` in a schema (`CREATE SCHEMA test_s; CREATE TABLE test_s.users ...`) and pass `"test_s"` into `NewSchema`, or (b) leave tables in `public` and pass `"public"` — the latter is lower-churn.
- `internal/adapters/postgres/schema_validator_test.go` (lines 74, 144) — same change.
- `docker-compose.yaml`: keep `DB_SCHEMA=public` for local dev; the change is transparent.

**Test strategy:**

- Unit: the two repository tests already run against a testcontainer; pass them a `public` schema and assert the `FROM` clause in generated queries is `"public"."stores"` (inspect via a prepared-statement fixture or a round-trip insert+select).
- Integration: add one targeted test that **creates a second schema in the same testcontainer, puts a decoy same-named table in `public`**, and asserts the repository still reads from the intended schema. This is the regression test for the exact "silent route" the DBA flagged.
- Manual: start `docker-compose.yaml` with `DB_SCHEMA=test_schema` and verify POST `/v1/stores` works end-to-end.

### 6.3 `event-publisher`

**Files touched:**

- `internal/outbox/repository.go` —
  - Struct gets `schema commonpg.Schema`; constructor takes it.
  - Replace each of the four `const ...Query = ...` string constants with a method that composes the query via `fmt.Sprintf(..., r.schema.Table("event_outbox"))`, or build the strings once in the constructor and store on the struct. Prefer the constructor approach — query strings are built once per repo instance, no per-call allocation.
- `cmd/eventpublisher/main.go:66` — construct `schema := commonpg.NewSchema(poolCfg.Schema)`; pass to outbox repository constructor.
- `internal/config/config.go:38–39` — replace the comment `// schema for search_path (set at pool level)` with `// schema under which event_outbox lives; every query qualifies explicitly`.
- `config.yaml:8` — update the trailing comment on `schema: esl` likewise.
- `internal/relay/relay_integration_test.go:54–167` — qualify `event_outbox` in every inline SQL string. Fixture can use `esl` (or a throwaway schema) inside the testcontainer.

**Test strategy:**

- Unit: add a test on the repository that builds an instance with a fake pool and asserts the built query strings contain `"esl"."event_outbox"` (substring match).
- Integration: the existing `relay_integration_test.go` already spins Postgres; assert it continues to pass with `schema = esl` after migration. Add the same decoy-in-`public` regression test as datafetch.
- Load: on the hot path (`FetchPending` calls per poll cycle), the sanitised string is computed once per pool and reused. No change in allocation profile.

### 6.4 `datapipeline`

This repo is the largest migration. Extra consumer surface: `internal/postgres/connection.go` wraps `commonpg.PoolConfig`.

**Files touched:**

- `internal/postgres/connection.go` — add a `Schema() commonpg.Schema` method on `ConnectionConfig` that returns `commonpg.NewSchema(c.Schema)`. This keeps downstream consumers from touching both the raw string and the helper.
- `internal/sink/postgres/postgres.go` — sink struct carries a `commonpg.Schema`; populated from `ConnectionConfig.Schema()` during construction.
- `internal/sink/postgres/query.go:148` — replace bare `%s` table name with `sink.schema.Table(sink.config.Tables[entityType].Name)`.
- `internal/sink/postgres/cdc.go:249–255` — same pattern for the CDC fetch query.
- `internal/sink/postgres/cdc.go:534–539` — qualify the hardcoded `event_outbox` via `sink.schema.Table("event_outbox")`. (Note: `event_outbox` owned by `datapipeline` writer here and by `event-publisher` reader — same physical table, same schema binding.)
- `internal/sink/postgres/errors.go:138–141` — qualify `records_with_errors` via `sink.schema.Table("records_with_errors")`.
- `internal/state/postgres/postgres_state.go:105, 159, 213, 250` — state store struct carries a `commonpg.Schema`; qualify `s.tableName` / `s.storeTableName` at query-build time. The table-name strings themselves stay in config; only the FROM/INTO expression becomes `s.schema.Table(s.tableName)`.
- `internal/sink/postgres/config.go` / `internal/state/postgres/config.go` — surface the schema to the components. The existing `Schema` field on `ConnectionConfig` stays; the helper is what flows into the component, not the raw string.
- All fixtures in `*_integration_test.go` under `internal/sink/postgres/` and `internal/state/postgres/`: when they `CREATE TABLE foo (...)` in a testcontainer, wrap in `CREATE SCHEMA IF NOT EXISTS esl;` + qualified DDL, then point `ConnectionConfig.Schema = "esl"` in the fixture. (The previous choice of `public` was coincidental; moving to `esl` for tests also exercises the real production schema name.)

**Test strategy:**

- Unit: `query_test.go` already covers the `buildSchemaPlan` code path; extend it to assert the built query contains `"esl"."products"` (and similar) for every entity type.
- Integration: existing tests continue to pass once fixtures are updated. Add a decoy-in-`public` regression test for the sink.
- godog-e2e: smoke-run the e2e suite once after migration lands in DEV. No step defs issue SQL, so this is a proof of "nothing broke" not a coverage add.

### 6.5 `database`

**Files touched:**

- `sql/V1.0.0.21__pgbouncer_compat_fix_role_scope.sql` — new migration (content in §5.3 / §5.5).
- `flyway.conf` — add `flyway.placeholders.appRole=esluser` (per environment as appropriate; prod may override).

**Test strategy:**

- `docker compose up -d` locally; confirm `psql` shows `\drds esluser` includes `search_path = esl, public` and `extra_float_digits = 3`, but *not* `statement_timeout`.
- Confirm `\drds current_user` after the migration shows **no** `statement_timeout` setting (the RESET should have cleared V13's side-effect).
- Run a synthetic long DDL (`CREATE INDEX` on a large test table) through Flyway to verify no 30s cap.

---

## 7. Environment Rollout

### 7.1 Environments and their pgBouncer posture

| Env | pgBouncer? | Mode | Notes |
|-----|-----------|------|-------|
| Local (docker-compose) | No | — | Direct Postgres. Tests CI. |
| DEV | No (or session pooling — confirm) | — | First target after merge. |
| QA | Same as DEV — confirm | — | Intermediate gate. |
| TST | **Yes** | **Transaction** | Current blocker for datafetch boot. |
| PROD | **Yes** | **Transaction** | Final target. |

If DEV or QA are also pgBouncer-in-transaction-mode, they are effectively currently broken for any service using `common` and someone is keeping them running via env-specific workarounds — surface that during PR review. If they are direct Postgres or session pooling, they will mask the bug until TST.

### 7.2 Per-environment verification checklist

After each deploy of a service carrying the migration (PRs #2–#4, then the `v0.2.0` bump in #7):

1. **Boot succeeds.** No `08P01` in logs.
2. **Health / ready endpoints report green.** pool.Ping is schema-agnostic; this confirms the pool itself is healthy.
3. **One read and one write per table in the hot path.** Verify schema-qualified sites work against the live Postgres.
4. **`SHOW search_path`** from a ad-hoc session as the app role: should equal `esl, public` (if V21 landed) or the Postgres default `"$user", public` (if V21 deliberately omits the default). In neither case should it be the app-controlled value — that's the point.
5. **Decoy check (TST only, once).** DBA or platform engineer creates an empty `public.stores` table, runs a datafetch request for `stores`, confirms rows still come from `esl.stores`. Drop the decoy immediately after. Do this once pre-PROD; it's the single best confirmation that §3's qualification story holds.
6. **Outbox drain.** For `event-publisher` and `datapipeline`, watch the `event_outbox` table size and processed_at timestamps for at least one poll cycle to confirm the CDC path did not silently stall.

### 7.3 Rollback posture

Each service PR is independently revertable because the old code still works while `common` still sets `search_path` (pre-PR #6). The `common` `v0.2.0` bump is the only point where a rollback requires also rolling back `common` (republish `v0.1.x` as the pinned version on the affected service). Keep PR #6 small; keep `v0.1.x` tags available.

### 7.4 CI gate to catch missed qualification before TST

Add a pipeline job — in each service's repo — that spins up the existing Postgres testcontainer with pgBouncer in front, configured in transaction mode:

- Image: `bitnami/pgbouncer:latest` (or whichever the TST env uses; align to that exact version to avoid behaviour drift).
- Config: `pool_mode=transaction`, `ignore_startup_parameters=extra_float_digits,statement_timeout` (note: **not** `search_path`).
- Point `docker-compose.yml` / the test harness at pgBouncer instead of Postgres for one dedicated integration-test lane.

Two assertions this lane buys:

1. **Boot assertion.** The service comes up against pgBouncer-in-transaction-mode. If `common/postgres/pool.go` still sets `search_path`, this lane fails. (Post PR #6, always passes.)
2. **Qualification assertion.** Each integration test's Postgres fixture creates tables in `esl` **and leaves `public` empty**. pgBouncer does not set a `search_path` for the app role, so any unqualified reference will fail with `relation "X" does not exist` in that lane. Queries that pass in the ordinary testcontainer lane but fail here are the exact class of bug we are trying to prevent.

This lane replaces the "can the DBA undo this by adding `ignore_startup_parameters`?" conversation with a mechanical check that runs before every merge.

### 7.5 Suggested cadence

- DEV after each PR merges.
- QA after DEV has soaked for 24h.
- TST when QA is green; this is the first environment that *proves* the pgBouncer fix.
- PROD during the next scheduled deploy window after TST has soaked for 48h.

---

## 8. Risks and Silent-Behaviour Hazards

### 8.1 The headline risk: wrong-schema routing

Once `RuntimeParams["search_path"]` is removed and nothing replaces it server-side, any bare reference falls back to the Postgres default `"$user", public` for the session. If `public` contains a table of the same name (because someone copy-pasted a CREATE for debugging, because another extension put it there, because a disaster-recovery restore seeded into the wrong schema), the app will read/write the wrong data with no error. The §5.5 role-level `search_path = esl, public` is a backstop; the CI lane at §7.4 is the active guard; the decoy-check at §7.2 step 5 is the one-shot confirmation.

### 8.2 Hazards specific to ESL code

| Hazard | Exposure | Mitigation |
|--------|----------|------------|
| Unqualified `nextval('seq')` in Go | None. No Go code issues `nextval`. Sequences are driven by `DEFAULT nextval(...)` in DDL, which Postgres OID-resolves at table-creation time. | No change; mention in PR description so future reviewers don't re-add. |
| `gen_random_uuid()` default on `event_outbox.id` | Function lives in `pg_catalog` (post-16) or in `pgcrypto`; in either case resolved before `esl` / `public`. Not at risk. | No change. |
| Trigger function bodies referencing unqualified names | Already fully qualified (`esl.sync_state`, `esl.store_sync_state`, `esl.event_outbox`). Verified by §2.5. | No change. |
| `pg_trgm` extension lives in `public` | Used only via operator class `gin_trgm_ops` in GIN index definitions. Operator classes do not go through `search_path`. | No change. |
| Custom function `esl.cleanup_delivered_events()` | Not called from any Go service today; invoked manually or by a cron. If ever called from Go, must be qualified `esl.cleanup_delivered_events()`. | Flag in the plan; no immediate action. |
| Views | None in migrations 01–20. | No action. |
| PL/pgSQL referencing unqualified names inside function bodies | Audit shows all function bodies qualify. | Add a Flyway lint step later: grep for `FROM [a-z]`, `INTO [a-z]`, `UPDATE [a-z]`, `DELETE FROM [a-z]` inside function bodies. |
| `RETURNING` clauses with unqualified expressions | `RETURNING id, finished_at` in state store — column references only, no table refs. Safe. | No change. |
| Prometheus metrics queries | `datafetch` metrics are counter/histogram only — no SQL pulled from Postgres. | No change; re-audit if a metrics-from-SQL collector is ever added. |
| Application_name passed as another RuntimeParam | `common/postgres/pool.go:126` also sets `application_name`. pgBouncer **does** allow `application_name` on StartupMessage in default config — confirm against the TST pgBouncer's allowed list. If rejected, same removal pattern; less urgent because `application_name` is cosmetic. | Verify during TST rollout; add to removal scope if broken. |
| `extra_float_digits` | V13 set it on the Flyway role. Flyway IS the JDBC consumer (pgJDBC 42.x) — it sends `extra_float_digits` on StartupMessage, pgBouncer strips it, the role default restores it. V13's targeting is correct for this line. | Keep as-is. V21 must NOT reset it; resetting would re-break Flyway behind pgBouncer. |
| `statement_timeout` regression at Flyway | V13 set it on `esluser`; V21 resets it. Any Flyway migration that ran *between* V13 and V21 under a long DDL may have silently timed out. | Audit `flyway_schema_history` for failed migrations with `statement timeout` error text, before shipping V21. |
| datapipeline's `godog-e2e/domain/db.go` opening its own pool | Uses pgx stdlib, no search_path. Step defs don't issue business SQL today. | Watch for drift in future step packs; no immediate action. |
| Common library's `pool_integration_test.go` breakage | Will fail the day PR #6 ships. | Rewritten in PR #6 as part of the same commit. |

### 8.3 Hazards not in scope

- Migrating `application_name` out of RuntimeParams — only if pgBouncer rejects it in the TST config.
- Splitting Flyway and app roles — prudent hygiene but explicitly out of this plan's scope. The V21 placeholder approach is forward-compatible with that split.
- Adding a `search_path` diff alert (e.g. a Grafana panel on `pg_settings` deltas) — a nice operational tripwire, but schedule as a follow-up after the rollout is complete.

---

## 9. Open Questions (for owner)

1. **Is the TST pgBouncer still on the same image/version that DEV+QA expect?** pgBouncer ≥ 1.21 supports `prepared_statements = true` in transaction mode, which changes the posture of pgx prepared statements dramatically. If TST is older, our pool may still fail for an unrelated reason once search_path is gone.
2. **Does production use `esluser` for both Flyway and apps, or will that split before this plan ships?** V21 resets `statement_timeout` via `current_user`, which works only while Flyway runs V21 from the same role it ran V13. A split between V13 and V21 would leave the 30s cap stuck on the old role and V21 resetting the wrong one.
3. **Are any JDBC consumers of this Postgres expected to exist *besides* Flyway?** None found; Flyway is the only JDBC client in scope. Confirming this validates that V13/V21's `extra_float_digits` role can remain narrowly the Flyway role.
4. **Are there any cron jobs or admin scripts connecting outside pgBouncer and assuming `search_path = esl`?** None found in `esl` repos; confirm with platform ops before PR #6.
5. **Confirm the DEV and QA pgBouncer posture.** If DEV is pgBouncer-in-transaction-mode, the TST boot failure should also occur there — which either means it isn't, or somebody has a local override.
