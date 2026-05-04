# Trunk Based Development - CI/CD Blueprint for ESL Projects

## Source

Based on the internal document: **DEVP-Trunk Based Development para Aplicações Docker** (2025-04-07)

---

## 1. The Model at a Glance

Trunk Based Development (TBD) replaces GitFlow. There are **no** `develop`, `release`, or `hotfix` branches.

**Only two ways to commit:**

| Method | When to use |
|--------|------------|
| Direct commit to `main` | Small, safe changes (config tweaks, typo fixes, minor refactors) |
| Short-lived feature branch `feature/{JIRA_ID}` | Any change needing review; must merge within **1-2 days max** |

**Commit messages must follow [Conventional Commits](https://www.conventionalcommits.org/):**

```
feat:     New functionality
fix:      Bug fix
chore:    Dependency updates, maintenance
refactor: Code restructuring without behavior change
BREAKING CHANGE:  Significant/incompatible changes
```

---

## 2. Repository Structure (Required)

Every Docker-based project must have this structure:

```
project-root/
├── Dockerfile                              # Required at root (based on template)
├── config-workflows/
│   ├── config-files/
│   │   ├── config.yaml                     # Pipeline behavior config
│   │   ├── images-config.yaml              # Docker images to build
│   │   ├── deploy-config.yaml              # Per-environment deploy settings
│   │   └── security_config.yaml            # Security scan toggles
│   └── scripts/
│       ├── application/
│       ├── deploy/
│       ├── dockerfile/
│       ├── package/
│       └── templates/
└── .github/
    └── workflows/                          # DO NOT MODIFY these - auto-generated
        ├── artifactoryBuildReusable.yaml
        ├── artifactoryDeployReusable.yaml
        ├── artifactoryRetagReusable.yaml
        ├── cleanGHCRImages.yaml
        └── list_old_branchesReusable.yaml
```

**Critical rule:** Never modify or add workflows under `.github/workflows/`. If something is missing, create a Jira dependency for the DevTools&Pipelines team.

---

## 3. Configuration Files Checklist

### 3.1 `config.yaml` — What the pipeline does

```yaml
stack: dotnet-sdk-9.0        # Change to match your stack
platform: dummy              # Leave as-is unless instructed
docker_container_image: true
deploy_onprem: false
application_build: false
package_build: false
registry: ghcr.io
run_unit_tests: false        # Set true when tests exist
run_integration_tests: false # Set true when tests exist
run_code_coverage: false     # Set true when coverage is configured
run_sonarqube: false         # Set true when SonarQube is configured
run_flyway: false            # Set true for database migration projects
```

**Action per project:** Review and set `run_unit_tests`, `run_integration_tests`, `run_code_coverage`, and `run_sonarqube` to `true` once the project supports them.

### 3.2 `images-config.yaml` — Docker images to build

For a single-image project:
```yaml
images:
  - name:                    # Empty name = image named after the repo
    dockerfile: Dockerfile
```

For multi-image (e.g., app + database):
```yaml
images:
  - name:
    dockerfile: Dockerfile
  - name: db                 # MUST be "db" for database images
    dockerfile: DockerfileFlyway
```

### 3.3 `deploy-config.yaml` — Per-environment overrides

```yaml
dev:
  runMigrations: true
  logLevel: "debug"
  keepReleases: 3
pp:
  runMigrations: true
  logLevel: "info"
  keepReleases: 5
prd:
  runMigrations: false
  logLevel: "warn"
  keepReleases: 10
```

Teams can add keys and change values but must **not** alter the structure.

### 3.4 `security_config.yaml` — Security scans

```yaml
run_secret_scanning: true
run_sast: false              # Enable when ready
run_sca: false               # Enable when ready
run_shell_check: true
run_scan_dangerous_commands: true
```

Changes must be validated/approved by the security team.

---

## 4. Dockerfile Rules

The Dockerfile must follow a **two-stage** pattern:

### Stage 1 — Build + Tests + SonarQube

```dockerfile
FROM {{BUILD_IMAGE}} AS build
WORKDIR /src
COPY . .

# Restore dependencies
RUN {{RESTORE_COMMAND}}

# Build
RUN {{BUILD_COMMAND}}

# Tests — outputs MUST go to these paths:
RUN mkdir -p /reports/unittests
RUN mkdir -p /reports/integrationtests
RUN {{TEST_COMMAND}}    # Output to /reports/testresults

# SonarQube reports to /reports/sonar

# Publish
RUN {{PUBLISH_COMMAND}} # Output to /app/publish
```

### Stage 2 — Runtime

```dockerfile
FROM {{RUNTIME_IMAGE}}
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT [${ENTRYPOINT_CMD}]
```

**Mandatory output paths:**
- `/reports/testresults` — test results
- `/reports/sonar` — SonarQube reports
- `/app/publish` — application binaries

For Go projects (datafetch, datapipeline), the existing multi-stage Dockerfiles already follow this pattern with builder + distroless runtime.

---

## 5. Delivery Pipeline — Step by Step

### Development (DEV/TST)

```
1. Code on main (direct commit or feature branch PR)
2. Push/merge to main triggers "Artifactory Build Reusable" automatically
3. Image is built and pushed to GHCR with TIMESTAMP tag (e.g., 20250730131211)
4. Check: GitHub Actions → Artifactory Build Reusable → latest run
5. Manual trigger: "Deploy App Reusable" → select TST environment + tag
```

### Pre-Production (PP)

```
6. Once validated in TST, run "Artifactory Retag Reusable"
   → Select "pre-production" environment
   → Paste the TIMESTAMP tag from TST
   → Creates a beta version tag: v1.2.0-beta.1
7. Manual trigger: "Deploy App Reusable" → select PP environment + beta tag
```

### Production (PRD)

```
8. Once validated in PP, run "Artifactory Retag Reusable"
   → Creates final version tag: v1.2.0
9. Manual trigger: "Deploy App Reusable" → select PRD environment + version tag
   → For PRD: pipeline creates a PR for the support team to approve
10. After approval, ArgoCD picks up the change and deploys
```

### Tag Format Summary

| Environment | Tag Format | Example |
|-------------|-----------|---------|
| DEV / TST | TIMESTAMP | `20250730131211` |
| PP | Semantic + beta | `v1.2.0-beta.1` |
| PRD | Semantic | `v1.2.0` |

---

## 6. BugFix / Hotfix Process

There are **no special branches** for bugs or hotfixes. The process is identical:

1. Fix directly on `main` or via a short `feature/fix-{JIRA_ID}` branch
2. Same build → retag → deploy pipeline (TST → PP → PRD)
3. Use `fix:` commit prefix

---

## 7. Current State of ESL Projects

*Last verified: 2026-04-29 against `/Users/joaopires/Projects/sonae/esl/`*

| Project | Language | Dockerfile @ root | Tests written | Tests enabled in pipeline | Image name (config) |
|---------|----------|-------------------|---------------|---------------------------|---------------------|
| **common** | Go (shared lib) | Missing | Yes (unit + integration) | No | empty → repo-named |
| **database** | Flyway 12.1.0-alpine | Present | N/A | N/A | `application` ⚠ blueprint says `db` |
| **datafetch** | Go | Present (multi-stage distroless) | Yes (unit + integration) | No | `application` |
| **datapipeline** | Go | Present (multi-stage distroless, digest-pinned) | Yes (unit + integration) | No | `application` |
| **event-publisher** | Go + CGO (distroless-base/glibc) | Present *(added since original blueprint)* | Yes (unit + integration) | No | empty → repo-named |
| **go-solace-sdk** | Go SDK | Missing | Yes (unit + integration) | No | empty → repo-named |

All six repos have the standard `.github/workflows/` set and `config-workflows/config-files/` (config, images, deploy, security).

### Cross-cutting gaps (affect every project)

1. **`stack: dotnet-sdk-9.0`** in every `config.yaml` — no project is .NET. Need the correct Go stack identifier from DevTools&Pipelines.
2. **`run_unit_tests` / `run_integration_tests` / `run_code_coverage` / `run_sonarqube` all `false`** — tests exist in code, the pipeline just doesn't run them.
3. **No SonarQube wiring** — `run_sonarqube: false` everywhere; no `sonar-project.properties` or scanner step.
4. **`run_sast` / `run_sca` are `false`** in every `security_config.yaml` — needs security-team approval to flip on.
5. **`deploy-config.yaml` only defines a `dev:` block** with `runMigrations: true` — `tst`, `pp`, `prd` blocks are missing.
6. **Image-name convention inconsistent** — `datafetch`, `datapipeline`, `database` use `name: application`; `common`, `event-publisher`, `go-solace-sdk` leave it empty (= repo-named, per blueprint).
7. **Go Dockerfiles emit no test/Sonar reports** — no `/reports/testresults` or `/reports/sonar` outputs. Decision needed: add a test stage to each Dockerfile, or run `go test` in the pipeline outside the image build.

### Action items per project

**datafetch & datapipeline** (most ready):
- [ ] Fix `stack` field to the Go identifier
- [ ] Resolve gap 7 (test stage in Dockerfile, or pipeline-side `go test`)
- [ ] Flip `run_unit_tests`, `run_integration_tests`, `run_code_coverage` to `true`
- [ ] Decide whether `name: application` should become empty (repo-named) for consistency

**event-publisher** (Dockerfile now exists, otherwise same posture):
- [ ] Same as datafetch/datapipeline
- [ ] Confirm pipeline build agent supports `--mount=type=secret,id=github_token_packages` (CGO build needs the Solace SDK fetched from a private repo)

**database**:
- [ ] Fix `stack` field
- [ ] Verify `images-config.yaml` — currently `name: application`, blueprint mandates `name: db` for Flyway images; likely a misconfiguration
- [ ] Confirm Flyway migrations run via `runMigrations: true` per env

**common** (Go shared library, no main binary):
- [ ] Decide: produce a Docker image, or set `package_build: true` / `docker_container_image: false`?
- [ ] If image: create Dockerfile from `config-workflows/DockerFile/Dockerfile-template`
- [ ] Fix `stack` field; enable tests

**go-solace-sdk** (Go SDK, package-style):
- [ ] Same decision as `common` — `docker_container_image: true` is probably wrong for an SDK
- [ ] Fix `stack` field; enable tests

**All projects**:
- [ ] Add `tst`, `pp`, `prd` blocks to `deploy-config.yaml` with team-specific overrides
- [ ] Configure SonarQube (project key, scanner integration, `run_sonarqube: true`)
- [ ] Coordinate with security team to enable `run_sast` and `run_sca`
- [ ] Confirm feature branches use `feature/{JIRA_ID}` and commits use Conventional Commits

---

## 8. Day-to-Day Developer Workflow

```
# 1. Start work — always from latest main
git checkout main && git pull

# 2a. Small change — commit directly
git commit -m "fix: correct timeout in Solace reconnection"
git push origin main

# 2b. Larger change — feature branch
git checkout -b feature/ESL-1234
# ... work ...
git commit -m "feat: add batch processing to datafetch"
git push origin feature/ESL-1234
# Open PR → merge within 1-2 days

# 3. Monitor build
# Go to GitHub Actions → Artifactory Build Reusable

# 4. Deploy to TST
# GitHub Actions → Deploy App Reusable → Run workflow
#   Environment: tst
#   Tag: <timestamp from build>

# 5. Promote to PP
# GitHub Actions → Artifactory Retag Reusable → Run workflow
#   Environment: pre-production
#   Tag: <timestamp tag>
# Then deploy same way with beta tag

# 6. Promote to PRD
# GitHub Actions → Artifactory Retag Reusable → Run workflow
#   Environment: production
#   Tag: <beta tag>
# Then deploy — PR created for support team approval
```

---

## 9. Key Contacts

| Need | Contact |
|------|---------|
| Pipeline issues or new workflow needs | DevTools&Pipelines team (Jira dependency) |
| Kubernetes repo config | MCDIGITAL-teamcloudadmins@mc.pt |
| Security config approval | Security team |

---

## 10. Rules to Remember

1. **Never modify `.github/workflows/`** — request changes via Jira
2. **Never create** `develop`, `release`, or `hotfix` branches
3. **Feature branches live max 1-2 days** then merge to main
4. **All commit messages** must follow Conventional Commits
5. **Dockerfile must output** to `/reports/testresults`, `/reports/sonar`, `/app/publish`
6. **Consult `config-workflows/scripts/` READMEs** before making config changes
7. **Secrets and sensitive config** go in GitHub Environments, never in code
