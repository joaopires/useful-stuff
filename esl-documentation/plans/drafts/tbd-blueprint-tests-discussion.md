# TBD Blueprint — Open Questions on Test Execution

Notes from a discussion reviewing `trunk-based-development-blueprint.md` and the
template folder at `/Users/joaopires/Projects/sonae/esl/database/config-workflows/`.

---

## Starting question

Does the blueprint explain how to enable unit and integration tests for an app?

**Short answer:** Only at a high level. It tells you which `config.yaml` toggles
to flip (`run_unit_tests`, `run_integration_tests`, `run_code_coverage`) and
which output paths to use (`/reports/unittests`, `/reports/integrationtests`,
`/reports/testresults`, `/reports/sonar`), but not how to wire up a test runner
or where the tests actually execute.

---

## Where tests run in the platform's model

Per the Dockerfile template (`config-workflows/scripts/dockerfile/Dockerfile-template`),
tests run **inside Stage 1 of the Dockerfile** — i.e. during `docker build`:

1. `FROM {{BUILD_IMAGE}} AS build`
2. Restore dependencies
3. Build
4. `mkdir -p /reports/unittests` + `mkdir -p /reports/integrationtests`
5. `RUN {{COMANDO_UNIT_TEST}}` / `RUN {{COMANDO_INTEGRATION_TEST}}`
6. SonarQube into `/reports/sonar`
7. Publish to `/app/publish`
8. Stage 2 copies both `/app/publish` and `/reports` into the runtime image.

This is a deliberate "test inside the build" pattern — uniform CI contract
across stacks, the reusable workflow only needs to extract `/reports/` from the
built image.

---

## Why this is awkward for our projects

We use **Testcontainers** for integration tests. Testcontainers needs a Docker
daemon, but `docker build` runs in an isolated build container with no Docker
socket. Workarounds (DinD, mounting the host socket via BuildKit) are all bad:
require `--privileged`, expose security holes, leak containers, and most
managed CI (including reusable GH Actions workflows) won't allow them.

Result: integration tests inside `docker build` is the single worst combination
for this pattern.

---

## What the templates folder actually supports

The README at `config-workflows/scripts/templates/README.md` shows an example
workflow (lines 156-178) that runs `./build.sh`, `./unit-tests.sh`, and
`./integration-tests.sh` as **plain GitHub Actions steps**, not inside Docker:

```yaml
- name: Build
  run: ./build.sh
- name: Run Unit Tests
  run: ./unit-tests.sh
- name: Run Integration Tests
  run: ./integration-tests.sh
```

So the same `.sh` template scripts can be executed in two places:

1. **Inside the Dockerfile** — `RUN ./unit-tests.sh` (what the Dockerfile
   template emphasises). Fine for unit tests, painful for Testcontainers.
2. **As GH Actions steps directly on the runner** — Testcontainers works
   normally because the runner has a Docker daemon.

---

## Where the blueprint draft is too thin

Things the blueprint should add:

- `# syntax=docker/dockerfile:1.4` directive is mandatory (needed for
  `RUN --mount=type=secret`).
- Predefined ARGs/secrets the platform injects:
  - `SonaeDev_UserName` / `SonaeDev_Password` (Sonae NuGet)
  - `SonaeDev_TelerikUser` + `sonaedev_telerikpassword` (secret)
  - `sonae_rootca_cert` (secret) — Sonae root CA
  - `GITHUB_ACTOR` + `github_token_packages` (secret)
  - `SONAR_PROJECT_KEY`, `SONAR_HOST_URL`, `sonar_token` (secret)
- Stage 2 also copies `/reports`: `COPY --from=build /reports /reports`. The
  reports travel with the runtime image.
- The `.sh` script templates pattern:
  - `build-template.sh` → copy to `build.sh`
  - `unit-tests-template.sh` → copy to `unit-tests.sh`
  - `integration-tests-template.sh` → copy to `integration-tests.sh`
  - `sonar-tests-template.sh` → copy to `sonar-tests.sh`
  Uncomment the block for your stack, adapt paths.
- Scripts run from repo root (`/home/runner/work/<repo>/<repo>` in GH Actions).

---

## Open question for DevTools&Pipelines team

Question to send them:

> For projects using Testcontainers, can we run `unit-tests.sh`,
> `integration-tests.sh`, and `sonar-tests.sh` as GitHub Actions steps on the
> runner instead of as `RUN` instructions inside the Dockerfile? If yes:
> - What does the reusable workflow expect for report consumption —
>   `actions/upload-artifact` of `/reports/`? A specific path?
> - Should `run_unit_tests` / `run_integration_tests` in `config.yaml` still
>   be `true`?
> - Same question for SonarQube (`run_sonarqube`).

The platform's reusable workflows under `.github/workflows/` are the binding
constraint (rule #1 of the blueprint: don't modify them). Their expectations
determine whether running tests on the runner is actually viable, regardless
of what the `.sh` script templates technically allow.

---

## Decisions to make once we have their answer

- **If runner-side tests are supported:** drop `RUN {{COMANDO_UNIT_TEST}}` and
  `RUN {{COMANDO_INTEGRATION_TEST}}` from our Dockerfile entirely. Keep
  build + publish in Stage 1. Run tests as separate Action steps.
- **If only Dockerfile-side is supported:** keep unit tests in the Dockerfile
  (no Testcontainers needed), escalate integration tests as a Jira dependency
  to DevTools&Pipelines — they need to provide a hook for runner-side
  integration tests, or we accept that integration tests run elsewhere
  (separate workflow) and aren't part of the gating build.
- **Hybrid (most likely):** unit tests in Dockerfile, integration tests on
  runner. Need the team to confirm reports get picked up.

---

## Action items (per project, after team answers)

For `datafetch` and `datapipeline` (Go, most ready):
- [ ] Fix `stack: dotnet-sdk-9.0` in `config.yaml` → correct Go stack identifier
- [ ] Set `run_unit_tests: true` once tests output to `/reports/unittests`
- [ ] Decide unit/integration test execution location based on team answer
- [ ] Verify Dockerfile outputs match required paths

For `database`, `common`, `event-publisher`, `go-solace-sdk`:
- [ ] See section 7 of the blueprint draft — Dockerfile creation /
      verification still applies regardless of where tests run.
