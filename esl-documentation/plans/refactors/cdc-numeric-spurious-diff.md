# CDC Spurious Diff on NUMERIC Columns

**Status:** SHIPPED 2026-05-05 ([datapipeline PR #36](https://github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-datapipeline/pull/36)).
**Owner:** datapipeline.
**Bug surface:** `event_outbox` rows with `event_type=UPDATED` whose `payload` reflects only a *type/format* change on NUMERIC columns, not a value change.

## Validation

Verified end-to-end against local Vusion sync after merge: product UPDATEDs dropped from 3700 → 15 (only the genuine `matching_*` / `modification_date` changes remain). Zero `price` / `custom_precioantes` diffs in the post-fix outbox. Drift guard runs at startup with no WARN under the current schema.

## Symptom

Production outbox rows (2026-05-05) where `payload` shows `new` and `old` differing only in JSON type or scale formatting:

```jsonc
// price = NUMERIC(12,2); custom_precioantes = NUMERIC(12,2)
{"price": {"new": 8,    "old": "8.00"},  "custom_precioantes": {"new": "8.0",  "old": "8.00"}}
{"price": {"new": 49.9, "old": "49.90"}, "custom_precioantes": {"new": "49.9", "old": "49.90"}}
{"price": {"new": 15,   "old": "15.00"}, "custom_precioantes": {"new": "15.0", "old": "15.00"}}
{"price": {"new": 21,   "old": "21.00"}, "custom_precioantes": {"new": "30.0", "old": "30.00"}}
```

The numeric values are equal; only textual representation differs. Each row triggers a downstream `UPDATED` event for no real change.

### Production-data evidence (local Postgres snapshot, 2026-05-05)

Validated against the local `event_outbox` (3958 UPDATED rows total):

| Entity | Count | Notes |
|---|---|---|
| `product` | 3700 | spurious-dominated |
| `label` | 258 | real changes (timestamps, signal quality, transmitter swaps) |

Per-field on `product` UPDATEDs:

| Field | Diffs emitted | Numerically equal (spurious) | % spurious |
|---|---|---|---|
| `price` | 3597 | 3597 | **100%** |
| `custom_precioantes` | 3613 | 3613 | **100%** |
| All others combined | ≤4 each | n/a | real |

Eliminating both numeric-spurious diffs would drop **3696 of 3700** product UPDATEDs (99.9%); only 4 represent real changes.

A-strict (number-vs-string only, `price` only) would eliminate just **83 of 3700** (2.2%) — confirming that `(string, string)` decimal-formatted columns drive almost all of the noise.

## Root cause

Two asymmetries in [`internal/sink/postgres/cdc.go`](../../../sonae/esl/datapipeline/internal/sink/postgres/cdc.go):

1. **Read path (DB → `oldVal`)** — `buildFetchQuery` casts every column with `::TEXT` (cdc.go:238). NUMERIC values come back as Go `string` preserving stored scale: `"8.00"`, `"49.90"`.
2. **Write path (Vusion → `newVal`)** — Vusion responses are decoded with default `json.Decoder.Decode(&map[string]any)` (no `UseNumber()`). JSON numbers become Go `float64`; JSON strings stay strings. Vusion's wire contract uses **string / integer / timestamptz / boolean** per field — so a NUMERIC DB column may be sourced from either a JSON number (e.g. `price: 8`) or a JSON string (e.g. `custom_precioantes: "8.0"`).
3. **Comparison** (cdc.go:485): `normalizeValue(newVal) != normalizeValue(oldVal)`. `normalizeValue` (cdc.go:284) is type-driven; its `string` branch is a passthrough and its `float64` branch produces `"8"` for whole numbers — neither path canonicalizes scale, so `"8.00"` ≠ `"8"` and `"8.0"` ≠ `"8.00"`.
4. **Payload write** — `normalizePayloadValue` only canonicalizes timestamps; the original `float64` and `string` survive into JSONB → asymmetric `{"new": 8, "old": "8.00"}`.

### Vusion type → Go type matrix (post-decode)

| Vusion contract | JSON wire | Go type after default `Decode` | Example |
|---|---|---|---|
| `string` | string | `string` | `"BomDia"`, `"8.0"` |
| `integer` | number | `float64` | `8`, `49.9` |
| `timestamptz` | string | `string` (parsed to `time.Time` only on the *write* side via `serialize.go`) | `"2026-05-05T14:51:51.190Z"` |
| `boolean` | bool | `bool` | `true` |

JSON natively supports only `string / number / boolean / null / array / object`. Default Go decoding produces `float64` for every number (lossy past 2^53; not a concern at NUMERIC(12,2) magnitudes).

### DB column → comparison-time pair matrix

| Postgres type | After `::TEXT` | Vusion contract | Comparison pair | Broken? |
|---|---|---|---|---|
| `NUMERIC(p,s)` (price) | `string` `"8.00"` | integer → `float64` | `(string, float64)` | **YES** |
| `NUMERIC(p,s)` (custom_precioantes) | `string` `"8.00"` | string `"8.0"` → `string` | `(string, string)` differ in scale | **YES** |
| `TIMESTAMPTZ` | `string` `"… 14:51:51.19+00"` | timestamptz → `string` | both → `time.Time` UTC | OK |
| `INTEGER` | `string` `"5"` | integer → `float64` | both → `"5"` (whole-number branch) | OK *by coincidence* |
| `BOOLEAN` | `string` `"true"` | boolean → `bool` | both → `"true"` | OK |
| `VARCHAR / TEXT` | `string` | string → `string` | `(string, string)` | OK |
| `TEXT[]` | `"{a,b}"` | `[]string` → `[]any` | both → sorted JSON | OK |

## Approaches considered

### A — Heuristic decimal normalization in `normalizeValue`

- **A-strict** triggers only when one side is a Go-native number and the other is a numeric string. Safe (no false negatives) but **fixes only ~2.2% of observed noise** — leaves the dominant `custom_precioantes`-class case untouched.
- **A-pragmatic** also collapses `(string, string)` numeric-looking pairs. Risks **false negatives** on legitimate leading-zero codes (e.g. `"009648"` vs `"9648"` would be silently treated as equal). False negatives = silent data loss; worse than today's bug.
- **A-pragmatic-narrowed** (require `.` on both sides) shrinks the false-negative surface but is still a heuristic.

### B — Schema-aware normalization (column-type metadata)

- **B1-full** — declare full column types per entity in `TableConfig`. Enables decimal canonicalization for NUMERICs plus future-proofing for other type-asymmetry bugs. ~200–400 LOC.
- **B1-narrow** — declare only the *NUMERIC column set* per entity (`map[string]bool`). Gate decimal canonicalization on membership. Precise, no heuristics, ~10 LOC of wiring beyond the helper itself. Today's scope: **two columns** (`products.price`, `products.custom_precioantes`). Cleanly evolves into B1-full later.

### C — `shopspring/decimal` library

New dep for a textual problem; still requires A or B to know which fields are decimals; JSON has no decimal type so payload form is unchanged. No advantage over the chosen path.

### D — `json.Decoder.UseNumber()` on Vusion ingestion

Removes one of two asymmetries; doesn't fix the formatting asymmetry. Still need decimal canonicalization on top. Touches every other code path that reads `RawData`. Net negative.

### E — Drop `::TEXT` cast; pgx native decoding

Massive surface (timestamps, arrays, every type). High regression risk. Out of scope.

### F — Server-side change detection

Replaces the outbox-with-diff contract used by event-publisher / Solace. Different project.

## Recommendation: **B1-narrow**

Reasons:
- Fixes the observed bug for both `price` and `custom_precioantes` — eliminating ~99.9% of product UPDATED noise per the data audit.
- No heuristics; no false-negative risk on identifier-like strings.
- Tiny LOC delta vs. A-strict; cleanly extensible to B1-full when the next type-asymmetry bug appears.
- Comparison-only fix — does **not** mutate `normalizePayloadValue` or change the Solace wire contract (see "Payload shape" below).

## Payload shape (no change in this PR)

Per [phase2/cdc-event-publisher.md:112-117](../phase2/cdc-event-publisher.md), the published Solace event is **flat** — UPDATED transforms strip the `{old, new}` wrapper and ship only the `new` value. Consumers never see `old`, never see the asymmetric outbox shape.

Implications:
- The outbox `{old, new}` shape is internal/audit-only. We leave it alone — even when a real diff exists, the persisted payload retains the asymmetric form it has today (e.g. `{"new": 9.5, "old": "8.00"}` for a real change). No behavioral change for downstream.
- Mutating `normalizePayloadValue` to canonicalize numerics would change the `new` value Solace receives (e.g. `8` → `"8.00"`). That is a wire-format break; out of scope for this fix.

A future contract negotiation could canonicalize the persisted payload (Option α: scale-aware string per the column's declared scale). Tracked as deferred under Approach B1-full.

## Implementation plan

### Files

- `internal/sink/postgres/config.go` — extend `TableConfig` with `NumericColumns map[string]bool`.
- `internal/sink/postgres/cdc.go` — add `normalizeDecimal` helper, add `valuesEqual` wrapper, route comparison through it.
- All `TableConfig` construction sites — populate `NumericColumns` for `products` (`price`, `custom_precioantes`) and any others surfaced by audit.
- `internal/sink/postgres/cdc_test.go` — extend test suite (see below).
- `docs/postgres-sink.md` (if present) — document `NumericColumns` field.

### Helper: `normalizeDecimal`

```go
// normalizeDecimal canonicalizes any value that represents a decimal number
// to a stable string form: no trailing zeros after '.', no trailing '.',
// no leading zeros except "0" itself, explicit '-' for negatives.
//
// Recognized inputs: float64, int, int64, json.Number, and strings matching
// ^-?\d+(\.\d+)?$. Returns ("", false) otherwise.
func normalizeDecimal(v any) (string, bool)
```

Use `strconv.FormatFloat(_, 'f', -1, 64)` for `float64` (avoids `%g` scientific notation), regex-validate strings, then split on `.` and trim trailing zeros from the fractional part. Trim leading `+` is rejected (regex doesn't allow it) — falls back to non-decimal handling.

### `valuesEqual` (replaces direct `normalizeValue` equality at cdc.go:485)

```go
func valuesEqual(col string, newVal, oldVal any, numericCols map[string]bool) bool {
    if numericCols[col] {
        if a, okA := normalizeDecimal(newVal); okA {
            if b, okB := normalizeDecimal(oldVal); okB {
                return a == b
            }
        }
        // Fall through if either side doesn't parse as decimal —
        // means a NULL or unexpected value; preserve current semantics.
    }
    return normalizeValue(newVal) == normalizeValue(oldVal)
}
```

Threading: `numericCols` must reach the comparison site. Plumb through `classifyAndDiff` from the `entityGroup` (which already carries `tableName` and `conflictKeys`); add `numericColumns` alongside.

### Audit step (pre-merge)

Grep [migrations](../../../sonae/esl/database/sql/) for every `NUMERIC` column declaration across all entity tables:

```bash
grep -nE 'NUMERIC|DECIMAL' /Users/joaopires/Projects/sonae/esl/database/sql/*.sql
```

Today's expected output: `products.price`, `products.custom_precioantes`. If anything else surfaces, add it to the declared set.

### Optional drift guard (recommended)

At sink startup, query `information_schema.columns` for each entity table and assert that the declared `NumericColumns` is a subset of the real NUMERIC columns. Log a `WARN` (don't fail) if a NUMERIC column exists in the schema but isn't declared. Cheap one-time check; catches future schema drift.

```sql
SELECT column_name FROM information_schema.columns
WHERE table_schema = $1 AND table_name = $2 AND data_type = 'numeric';
```

### Test plan

In `internal/sink/postgres/cdc_test.go`:

1. **`TestNormalizeDecimal`** — table-driven helper coverage:
   - `float64(8)`, `int(15)`, `int64(21)`, `json.Number("8")` → `"8"`
   - `float64(49.9)`, `"49.90"`, `"49.9"` → `"49.9"`
   - `"0.10"`, `"0.1"`, `"0.100"` → `"0.1"`
   - `"-0.50"`, `"-0.5"` → `"-0.5"`
   - `"0"`, `"0.00"`, `float64(0)` → `"0"`
   - `"abc"`, `"1e5"`, `"+5"`, `nil`, `bool(true)` → `("", false)`
2. **`TestValuesEqual_NumericColumn_NumberVsString`** — `(float64(8), "8.00")`, `(float64(49.9), "49.90")`, `(int(21), "21.00")` all equal when col ∈ NumericColumns.
3. **`TestValuesEqual_NumericColumn_StringVsString`** — `("8.0", "8.00")`, `("49.9", "49.90")`, `("30.0", "30.00")` all equal when col ∈ NumericColumns.
4. **`TestValuesEqual_NumericColumn_RealDiff`** — `(float64(8), "9.50")`, `("8.0", "8.5")` → not equal.
5. **`TestValuesEqual_NonNumericColumn_StringPreserved`** — `("009648", "9648")`, `("00042", "42")`, `("8.0", "8.00")` → all emit diffs when col ∉ NumericColumns. **Regression guard against accidental widening.**
6. **`TestClassifyAndDiff_NumericNoSpurious`** — end-to-end:
   - existing `price="8.00"`, `custom_precioantes="8.00"`; RawData `price=float64(8)`, `custom_precioantes="8.0"` → zero events.
7. **`TestClassifyAndDiff_NumericRealChange`** — existing `price="8.00"`, RawData `price=float64(9.5)` → exactly one UPDATED event with `price` diff only. Asserts persisted payload retains today's heterogeneous shape (no `normalizePayloadValue` mutation).
8. **`TestClassifyAndDiff_MixedSpuriousAndReal`** — spurious `price` + real `name` change → UPDATED with **only `name`** in diff. Regression guard: spurious price must not sneak into payload.
9. **`TestTableConfig_NumericColumnsDeclared`** — assert config literal declares `price` and `custom_precioantes` for `products`. Cheap drift guard.
10. Extend existing `TestNormalizeValue`, `TestClassifyAndDiff_TypeNormalization`, `TestClassifyAndDiff_TimestampNormalization` — confirm no behavior change for non-numeric columns.
11. *(Optional, integration)* — `TestSink_NumericColumnsDriftCheck` against testcontainer: assert the declared set ⊆ live `information_schema` numeric columns.

### Documentation revision (post-merge)

- **[phase2/cdc-datapipeline.md](../phase2/cdc-datapipeline.md)**:
  - Line 27 ("Type comparison" row in the decisions table) — note column-aware decimal handling for declared NUMERIC columns.
  - Lines 294-308 (`normalizeValue` doc block) — document the new column-aware path; mention `valuesEqual` and `normalizeDecimal`.
  - Line 325 ("Both sides normalized to string before comparison") — clarify the NUMERIC-column branch.
  - Lines 599-605 (test list under "Pure unit tests") — append the new test names.
  - Line 647 (Known limitations) — note the hand-authored `NumericColumns` set + drift-guard option; future work = full column-type registry (B1-full).
- **[phase2/cdc-masterplan.md](../phase2/cdc-masterplan.md)** line 46 ("Type comparison strategy") — same edit as cdc-datapipeline.md line 27.
- **[phase2/cdc-postgres-package.md](../phase2/cdc-postgres-package.md)** — re-read post-merge; if it documents the `TableConfig` shape, append `NumericColumns`.
- **Repo `docs/postgres-sink.md`** (if present) — document `NumericColumns` config field.
- **Memory** — update [project_phase2_cdc_sink.md](memory/project_phase2_cdc_sink.md) to include the spurious-numeric-diff fix and the residual B1-full follow-up.

### Rollout

1. PR with config field, helper, comparison change, test suite, and docs update (per CLAUDE.md "Update `docs/` if public APIs, configuration, or architecture changed").
2. Run `go test ./...` (unit + integration). Verify no regressions in existing CDC integration tests.
3. Deploy dev → spot-check fresh sync against products: outbox UPDATED count should drop ~99% per the audit.
4. Deploy pp → confirm event-publisher Solace publish rate drops correspondingly. No consumer-side issues expected (wire format unchanged).
5. Production.

### Rollback

Single revert. No migrations, no consumer contract change. Worst case: re-introduces today's spurious-event behavior. No data corruption risk.

## Out of scope / follow-ups

- **B1-full (full column-type registry).** Track separately. Reuse `normalizeDecimal`/`parseTimestamp`. Trigger on next type-asymmetry bug or as part of a sink-package refactor.
- **Outbox payload canonicalization (Option α).** Requires consumer-side contract change; pair with B1-full and a Solace consumer audit.
- **Approach D (UseNumber).** Only if a related bug surfaces.
- **INTEGER fragility audit** — works today by coincidence (whole-number `float64` branch). Subsumed by B1-full.
- **Outbox backfill cleanup.** Existing spurious events already published; consumers are expected to be idempotent. No remediation in DB.

## Open questions

1. Drift guard at startup: do we want the `information_schema` check, or rely solely on `TestTableConfig_NumericColumnsDeclared` + audit discipline? Default proposal: include the check (cheap, one-time, logs warning only).
2. Plumbing path for `numericColumns` into `classifyAndDiff` — extend `entityGroup` struct, or pass via a per-entity `comparator` value? Default proposal: extend `entityGroup` for symmetry with existing `conflictKeys`/`tableName`.
