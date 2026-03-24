# Agent Handoff: Postgres Sink - Remove Dead 'WriteModeUpdate' Code

## Status

- **Date**: 2026-03-02
- **Topic**: Refactoring `internal/sink/postgres/postgres.go` to remove unused `WriteModeUpdate` logic.
- **Previous Agent**: Kilo Code (Code Reviewer / Architect)

## Context

The user asked if `WriteModeUpdate` (specifically line 594 in `internal/sink/postgres/postgres.go`) is needed, or if `WriteModeUpsert` is sufficient.

## Analysis

1. **Unreachable in Production**:
    The method `getEffectiveWriteMode` (lines 483-491) determines which write mode is used. It **only** returns:
    - `WriteModeInsert` (for full sync)
    - `WriteModeUpsert` (default for incremental)

    It never returns `WriteModeUpdate`. Therefore, the logic at line 594 inside `buildSchemaPlan` (case `WriteModeUpdate`) is never executed during normal operation.

2. **Upsert is Sufficient**:
    `WriteModeUpsert` uses `INSERT ... ON CONFLICT DO UPDATE`, which covers both:
    - **New records**: Inserts them.
    - **Existing records**: Updates them.

    This is more robust than a strict `UPDATE` (which would fail if the record doesn't exist) and is the standard pattern for idempotent data pipelines.

## Conclusion

The `WriteModeUpdate` logic is **dead code** in the production path and should be removed to simplify the codebase.

## Action Plan (Next Steps)

The next agent should execute the following changes in `internal/sink/postgres/postgres.go` and `internal/sink/postgres/postgres_test.go`:

1. **Remove `WriteModeUpdate` Constant**:
    - Remove `WriteModeUpdate WriteMode = "update"` (around line 33).

2. **Remove `WriteModeUpdate` Case in `buildSchemaPlan`**:
    - Remove the `case WriteModeUpdate:` block (around line 594).

3. **Remove `WriteModeUpdate` Logic in `prepareQuery`**:
    - Remove the `if writeMode == WriteModeUpdate` block that appends `record.ID` (around line 526).

4. **Remove `buildUpdateQueryString` Method**:
    - Remove the entire function (around line 665).

5. **Remove Deprecated Test Helper**:
    - Remove `buildUpdateQuery` (around line 702).

6. **Remove Unused Tests**:
    - In `internal/sink/postgres/postgres_test.go`, remove `TestPostgresSink_buildUpdateQuery` (around line 97) as it tests the deprecated helper.

After these changes, verify that the code compiles and tests pass:

```bash
go test ./internal/sink/postgres/...
```
