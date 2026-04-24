# Docker Private Module Auth — Rollout to Sibling Repos

## Context

The ESL platform has three sibling Go services under `sonaemc-instore/` that share:

- A private Go module dependency: `github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-common`.
- The same CI reusable workflow: `mcdigital-devplatforms/trunkbased-workflows-dispatch/.github/workflows/docker-image-build.yaml` (owned by DevTools&Pipelines — **cannot be modified**, per the trunk-based development policy).
- Similar multi-stage alpine-based Dockerfiles.

The `datapipeline` repo fix landed in PR #30 (merged 2026-04-24). This plan applies the same fix to:

- `lac1041-instoreorchestrator_esl-datafetch`
- `lac1041-instoreorchestrator_esl-event-publisher`

## The problem (recap)

`go mod download` fails inside the Docker builder with:
```
go: github.com/sonaemc-instore/...esl-common@...: exec: "git": executable file not found in $PATH
```

Two stacked issues:
1. Alpine builder doesn't include `git`, and Go falls back to `git` to fetch private modules.
2. Even with git installed, there is no credential configured for the private org.

## The fix contract

The reusable workflow already passes two relevant BuildKit secrets to `docker build`:
- `id=github_token, env=GITHUB_TOKEN` — repo-scoped, **insufficient** for cross-repo pulls.
- `id=github_token_packages, env=GH_TOKEN_PACKAGES` — **cross-repo scoped on sonaemc-instore org** (verified 2026-04-24 in datapipeline CI).

Consuming repo just needs to mount `github_token_packages` at build time and use it as a git HTTPS credential.

## Dockerfile changes (required)

In the builder stage:

1. Add `git` to `apk add`.
2. Set `ENV GOPRIVATE=github.com/sonaemc-instore/*` before `go mod download`.
3. Replace the `RUN go mod download && go mod verify` with a secret-mounted, auth-injecting version.

Reference diff (from datapipeline PR #30):

```dockerfile
# Install build dependencies (git required to fetch private modules)
RUN apk add --no-cache ca-certificates tzdata git

WORKDIR /build

# Bypass public proxy and checksum DB for private org modules
ENV GOPRIVATE=github.com/sonaemc-instore/*

COPY go.mod go.sum ./

# BuildKit secret mount injects GH token only for this layer — never stored in image.
# Credential is unset before the layer commits as defense-in-depth.
RUN --mount=type=secret,id=github_token_packages \
    git config --global url."https://x-access-token:$(cat /run/secrets/github_token_packages)@github.com/".insteadOf "https://github.com/" && \
    go mod download && go mod verify && \
    git config --global --unset url."https://x-access-token:$(cat /run/secrets/github_token_packages)@github.com/".insteadOf
```

Notes:
- `x-access-token` is GitHub's universal username for token auth — works for classic PATs, fine-grained PATs, and GitHub App installation tokens.
- The secret file exists at `/run/secrets/github_token_packages` only for that `RUN` step, then is gone.
- The final `git config --unset` is defensive — the secret mount already guarantees no leak, but explicit teardown makes the intent obvious.

## Makefile changes (if the repo has a `docker-build` target)

Update the target to:
1. Validate `GH_TOKEN_PACKAGES` is set; fall back to `gh auth token`.
2. Add `--secret id=github_token_packages,env=GH_TOKEN_PACKAGES` to the `docker build` invocation.

Reference pattern:

```make
## docker-build: Build Docker image (needs GH_TOKEN_PACKAGES or active `gh` auth)
docker-build:
	@echo "$(COLOR_BLUE)Building Docker image...$(COLOR_RESET)"
	@if [ -z "$$GH_TOKEN_PACKAGES" ]; then \
		echo "$(COLOR_YELLOW)⚠ GH_TOKEN_PACKAGES not set, falling back to 'gh auth token'$(COLOR_RESET)"; \
		GH_TOKEN_PACKAGES=$$(gh auth token 2>/dev/null) || { \
			echo "$(COLOR_YELLOW)✗ No token available. Set GH_TOKEN_PACKAGES or run 'gh auth login'$(COLOR_RESET)"; \
			exit 1; \
		}; \
	fi; \
	export GH_TOKEN_PACKAGES; \
	docker build \
		--secret id=github_token_packages,env=GH_TOKEN_PACKAGES \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT_SHA=$(COMMIT_SHA) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		-t $(DOCKER_IMAGE):latest \
		.
	@echo "$(COLOR_GREEN)✓ Docker image built: $(DOCKER_IMAGE):$(DOCKER_TAG)$(COLOR_RESET)"
```

## docker-compose.yml changes (if the repo has a `build:` block)

If the service declares `build:`, compose-driven builds need the secret too:

```yaml
services:
  <service-name>:
    build:
      context: .
      dockerfile: Dockerfile
      secrets:                          # NEW
        - github_token_packages         # NEW
      args:
        ...

# At the bottom of the file:
secrets:                                # NEW (top-level)
  github_token_packages:                # NEW
    environment: GH_TOKEN_PACKAGES      # NEW
```

Compose reads `GH_TOKEN_PACKAGES` from the shell env — no automatic `gh auth token` fallback. Document this in the repo's docs.

## Documentation changes

Update the repo's README build section and (if present) `docs/docker-deployment.md` to cover:
- **Prerequisite:** `GH_TOKEN_PACKAGES` env var, how to obtain a token.
- **Updated commands:** include `--secret id=github_token_packages,env=GH_TOKEN_PACKAGES`.
- **Troubleshooting entries** for three failure modes:
  - `exec: "git": executable file not found in $PATH` → verify `apk add ... git`.
  - `failed to solve: missing secret github_token_packages` → invocation lacks `--secret` flag.
  - `fatal: could not read Username` / `Repository not found` / 401/403 → token missing or wrong scope.

## Per-repo checklist

For each of `datafetch` and `event-publisher`:

- [ ] Create branch: `feature/docker-private-module-auth`.
- [ ] Verify `go.mod` actually imports the private dep (grep for `sonaemc-instore`). If not, skip this repo.
- [ ] Apply Dockerfile changes (sections: "Install build dependencies", "WORKDIR", `go mod download`).
- [ ] Apply Makefile changes if a `docker-build` target exists.
- [ ] Apply `docker-compose.yml` changes if a `build:` block exists.
- [ ] Update README + any `docs/docker-deployment.md`.
- [ ] Local validation:
  ```
  GH_TOKEN_PACKAGES=$(gh auth token) \
    docker buildx build \
      --secret id=github_token_packages,env=GH_TOKEN_PACKAGES \
      -t <repo>:test .
  ```
- [ ] Inspect the built binary to confirm the private dep is linked:
  ```
  CID=$(docker create <repo>:test) && \
    docker cp $CID:/app/<binary> /tmp/bin && \
    docker rm $CID && \
    go version -m /tmp/bin | grep esl-common
  ```
- [ ] Split commits:
  1. `fix(docker): fetch private modules via BuildKit secret` — Dockerfile only.
  2. `chore(build): wire GH_TOKEN_PACKAGES into Makefile and compose` — Makefile + compose.
  3. `chore(docs): document private module build requirements` — README + docs.
- [ ] Open PR using `.github/pull_request_template.md`; reference datapipeline PR #30 as the precedent.
- [ ] Monitor the CI run; if Image Build succeeds, ready for review.

## Risks / contingencies

- **`GH_TOKEN_PACKAGES` scope in CI:** verified cross-repo on sonaemc-instore for datapipeline. Expected to work identically for datafetch and event-publisher since they live in the same org and the token is org-scoped. If a CI run surprises with 401/403, escalate to DevTools&Pipelines via Jira.
- **Dockerfile divergence:** if datafetch or event-publisher have significantly different Dockerfile structures (not alpine, no multi-stage, etc.), the patch still applies in spirit — the three required changes (install git, set GOPRIVATE, mount secret for `go mod download`) are universal.
- **No `application_build`-stage impact:** the reusable workflow's `application_build` job runs Go tests/builds outside the Dockerfile. Our fix is Dockerfile-only and does not affect that path.

## References

- Datapipeline PR: https://github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-datapipeline/pull/30
- Datapipeline CI run that validated the fix: https://github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-datapipeline/actions/runs/24885474335 (Image Build 1m19s, green)
- Trunk-based development PDF: `/Users/joaopires/Projects/sonae/docs/DEVP-Trunk Based Development para Aplicações Docker-070426-110505.pdf`
