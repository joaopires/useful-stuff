# Event Publisher: OAuth2 Authentication for Solace

## Context

The Solace broker uses OAuth2 (client credentials flow). The `go-solace-sdk` already supports this via `WithOAuth2(clientID, clientSecret, tokenEndpoint, scope)`, which internally manages token acquisition, caching, and automatic refresh via a `TokenManager`. This plan migrates the event-publisher from basic auth to OAuth2.

## Current State

| Layer | File | Auth mechanism |
|-------|------|----------------|
| Config struct | `internal/config/config.go:78-102` | `Username` + `Password` fields |
| Config YAML | `config.yaml:22-23` | `username: admin` / `password: admin` |
| Client Config | `internal/messaging/solace/client.go:16-27` | `Username` + `Password` fields |
| Client creation | `internal/messaging/solace/client.go:38-39` | `solacesdk.WithBasicAuth(cfg.Username, cfg.Password)` |
| Config conversion | `internal/config/config.go:105-118` | Passes `Username`/`Password` to client config |
| Validation | `internal/config/config.go:191-193` | Requires `solace.username` |
| Docker Compose | `docker-compose.yml` | `username_admin_password=admin` |
| Integration tests | `internal/testutil/solace_container.go` | Basic auth with `admin/admin` |
| Integration tests | `internal/relay/relay_integration_test.go:105-116` | Basic auth via `solace.Config` |

---

## Plan

### Step 1: Add `auth_scheme` field to config with OAuth2 fields

**File: `internal/config/config.go`**

Add an `AuthScheme` field and OAuth2-specific fields to `SolaceConfig`:

```go
type SolaceConfig struct {
    Host     string `mapstructure:"host"`
    VPN      string `mapstructure:"vpn"`

    // authentication scheme: "basic" (default) or "oauth2"
    AuthScheme string `mapstructure:"auth_scheme"`

    // basic auth fields (used when auth_scheme is "basic")
    Username string `mapstructure:"username"`
    Password string `mapstructure:"password"`

    // OAuth2 client credentials fields (used when auth_scheme is "oauth2")
    ClientID      string `mapstructure:"client_id"`
    ClientSecret  string `mapstructure:"client_secret"`
    TokenEndpoint string `mapstructure:"token_endpoint"`
    Scope         string `mapstructure:"scope"`

    // ... (remaining fields unchanged)
}
```

**Env var mapping** (automatic via Viper):
- `SOLACE_AUTH_SCHEME` -> `solace.auth_scheme`
- `SOLACE_CLIENT_ID` -> `solace.client_id`
- `SOLACE_CLIENT_SECRET` -> `solace.client_secret`
- `SOLACE_TOKEN_ENDPOINT` -> `solace.token_endpoint`
- `SOLACE_SCOPE` -> `solace.scope`

### Step 2: Update config validation

**File: `internal/config/config.go` — `Validate()` method**

Replace the hardcoded `username` requirement with scheme-aware validation:

```
- If auth_scheme is "" or "basic":
    - solace.username is required (keep existing check)
- If auth_scheme is "oauth2":
    - solace.client_id is required
    - solace.client_secret is required
    - solace.token_endpoint is required
    - solace.scope is required
- If auth_scheme is anything else:
    - Return error: unsupported auth scheme
```

### Step 3: Update Solace client Config struct

**File: `internal/messaging/solace/client.go`**

Add OAuth2 fields to the `Config` struct:

```go
type Config struct {
    Host     string
    VPN      string

    AuthScheme    string
    Username      string
    Password      string
    ClientID      string
    ClientSecret  string
    TokenEndpoint string
    Scope         string

    ConnectTimeout      time.Duration
    ConnectRetries      int
    ReconnectRetries    int
    ReconnectWait       time.Duration
    KeepAlive           time.Duration
    ConfirmationTimeout time.Duration
}
```

### Step 4: Update `NewClient` to select auth option

**File: `internal/messaging/solace/client.go` — `NewClient()`**

Replace the hardcoded `WithBasicAuth` with a scheme switch:

```go
var authOpt solacesdk.ConnectionOption
switch cfg.AuthScheme {
case "oauth2":
    authOpt = solacesdk.WithOAuth2(cfg.ClientID, cfg.ClientSecret, cfg.TokenEndpoint, cfg.Scope)
default:
    authOpt = solacesdk.WithBasicAuth(cfg.Username, cfg.Password)
}

opts := []solacesdk.ConnectionOption{
    authOpt,
    // ... remaining options unchanged
}
```

### Step 5: Update `ToClientConfig` conversion

**File: `internal/config/config.go` — `ToClientConfig()`**

Pass the new fields through:

```go
func (s *SolaceConfig) ToClientConfig() solaceclient.Config {
    return solaceclient.Config{
        Host:          s.Host,
        VPN:           s.VPN,
        AuthScheme:    s.AuthScheme,
        Username:      s.Username,
        Password:      s.Password,
        ClientID:      s.ClientID,
        ClientSecret:  s.ClientSecret,
        TokenEndpoint: s.TokenEndpoint,
        Scope:         s.Scope,
        // ... remaining fields unchanged
    }
}
```

### Step 6: Update `config.yaml`

Add OAuth2 fields with comments showing all available options:

```yaml
solace:
  host: tcp://localhost:55554
  vpn: default
  # authentication scheme: "basic" or "oauth2"
  auth_scheme: basic
  # basic auth credentials (used when auth_scheme is "basic")
  username: admin
  password: admin
  # OAuth2 client credentials (used when auth_scheme is "oauth2")
  # client_id: ""
  # client_secret: ""
  # token_endpoint: ""
  # scope: ""
  topic_prefix: "in-store/orchestratoresl"
  # ... remaining fields unchanged
```

### Step 7: Update unit tests for config validation

**File: `internal/config/` (existing test files)**

Add test cases:
- Valid config with `auth_scheme: basic` (username required)
- Valid config with `auth_scheme: oauth2` (client_id, client_secret, token_endpoint, scope required)
- Invalid: `auth_scheme: oauth2` with missing client_id -> error
- Invalid: `auth_scheme: oauth2` with missing token_endpoint -> error
- Invalid: unknown auth_scheme -> error
- Default: empty auth_scheme defaults to basic auth behavior

---

## Docker Compose: OAuth2 for Local Development

### Reality check

Setting up OAuth2 locally with Solace is non-trivial because:
1. **OAuth2 cannot be configured via env vars** — requires post-startup SEMP v2 API calls
2. **TLS is mandatory** — Solace requires `https://` for all OAuth endpoints
3. **Needs an OAuth2 provider** — Keycloak or similar must run alongside Solace
4. **Self-signed certs** — must be generated and trusted by both Solace and Keycloak containers

### Recommended approach: keep basic auth for local dev, use OAuth2 in deployed environments

The `auth_scheme` field already supports both modes. For local development, keep `auth_scheme: basic` in `config.yaml`. In deployed environments (K8s), set `SOLACE_AUTH_SCHEME=oauth2` and the corresponding env vars.

**Rationale:** The docker-compose setup is for rapid local development. Adding Keycloak + TLS certs + SEMP provisioning scripts adds significant complexity for zero development value — the code path is the same regardless of auth scheme.

### If OAuth2 local setup is required anyway

Here's the full docker-compose evolution needed:

```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.2
    container_name: keycloak
    hostname: keycloak
    ports:
      - "7777:8080"    # HTTP (dev mode)
      - "7778:8443"    # HTTPS
    environment:
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
    command: start-dev --import-realm
    volumes:
      - ./dev/keycloak-realm.json:/opt/keycloak/data/import/realm.json
      - ./dev/certs/keycloak.crt:/etc/x509/https/tls.crt
      - ./dev/certs/keycloak.key:/etc/x509/https/tls.key
    networks:
      - solace-net

  solace:
    image: solace/solace-pubsub-standard:10.25.0.208
    container_name: solace-broker
    hostname: solace-broker
    depends_on:
      keycloak:
        condition: service_started
    ports:
      - "55554:55555"
      - "8080:8080"
      - "8008:8008"
    environment:
      - username_admin_globalaccesslevel=admin
      - username_admin_password=admin
      - system_scaling_maxconnectioncount=100
    shm_size: 2g
    ulimits:
      nofile:
        soft: 2448
        hard: 1048576
    volumes:
      - ./dev/certs/keycloak.crt:/usr/sw/jail/certs/keycloak.crt
    networks:
      - solace-net

  solace-init:
    image: curlimages/curl:latest
    depends_on:
      solace:
        condition: service_started
    entrypoint: /bin/sh
    command:
      - -c
      - |
        echo "Waiting for Solace SEMP API..."
        until curl -sf http://solace-broker:8080/SEMP/v2/config/about/api -u admin:admin; do
          sleep 3
        done
        echo "Configuring OAuth profile..."
        # Import Keycloak CA cert to Solace domain cert authorities
        curl -X POST "http://solace-broker:8080/SEMP/v2/config/domainCertAuthorities" \
          -u admin:admin -H "Content-Type: application/json" \
          -d '{"certAuthorityName":"keycloak-ca","certContent":"'"$(cat /certs/keycloak.crt)"'"}'
        # Create OAuth profile on default VPN
        curl -X POST "http://solace-broker:8080/SEMP/v2/config/msgVpns/default/authenticationOauthProfiles" \
          -u admin:admin -H "Content-Type: application/json" \
          -d '{
            "oauthProfileName": "keycloak",
            "oauthRole": "resource-server",
            "endpointDiscovery": "https://keycloak:8443/realms/solace/.well-known/openid-configuration",
            "endpointJwks": "https://keycloak:8443/realms/solace/protocol/openid-connect/certs",
            "usernameClaimName": "sub",
            "enabled": true
          }'
        # Enable OAuth on the VPN
        curl -X PATCH "http://solace-broker:8080/SEMP/v2/config/msgVpns/default" \
          -u admin:admin -H "Content-Type: application/json" \
          -d '{
            "authenticationOauthDefaultProfileName": "keycloak",
            "authenticationOauthEnabled": true
          }'
        echo "OAuth configured."
    volumes:
      - ./dev/certs:/certs:ro
    networks:
      - solace-net

networks:
  solace-net:
```

**Additional files needed:**
- `dev/certs/keycloak.crt` + `keycloak.key` — self-signed TLS cert (SANs: `keycloak`, `localhost`)
- `dev/keycloak-realm.json` — pre-exported Keycloak realm with a `solace` realm, a client (e.g. `event-publisher`), and appropriate scopes
- `dev/generate-certs.sh` — script to generate the self-signed certs

**config.yaml for OAuth2 local dev:**
```yaml
solace:
  host: tcp://localhost:55554
  vpn: default
  auth_scheme: oauth2
  client_id: event-publisher
  client_secret: <from keycloak realm config>
  token_endpoint: https://localhost:7778/realms/solace/protocol/openid-connect/token
  scope: solace:publish
```

---

## go-solace-sdk: OAuth2 Integration Test

The SDK has **zero E2E coverage** for OAuth2. Existing tests:
- `TestNewClientOAuth2` — creates a client but never connects
- `internal/auth/oauth_test.go` — tests `TokenManager` against `httptest.Server`, never a real broker
- `producer/topic_publisher_integration_test.go` — all tests use `WithBasicAuth`

This means the full chain (SDK acquires token → passes to Solace session → broker accepts it) is untested. This needs to be fixed in the SDK before the event-publisher adopts OAuth2.

### What's needed

A Keycloak container running alongside the existing Solace testcontainer on a shared Docker network, with the Solace broker configured to validate JWTs issued by Keycloak.

### Why Keycloak (not a mock)

- Solace **requires `https://`** for all OAuth endpoints (JWKS, discovery, introspection). A Go `httptest.NewTLSServer` running on the host is not reachable by the Solace container by hostname with a valid TLS cert.
- Keycloak has built-in HTTPS on port 8443 in dev mode, serves `.well-known/openid-configuration`, JWKS, and token endpoints out of the box.
- A pre-exported realm JSON makes setup fully reproducible — no manual config in the test.
- Keycloak is the industry standard for exactly this kind of test — lightweight alternatives (Dex, mock-oauth2-server) have less Go ecosystem usage and their own quirks.

### Architecture

```
┌──────────────────── Docker network: solace-oauth-test ────────────────────┐
│                                                                           │
│  ┌─────────────┐    JWKS/discovery (https)   ┌──────────────┐            │
│  │   Solace     │◄──────────────────────────── │   Keycloak    │            │
│  │   broker     │                             │   (port 8443) │            │
│  └──────┬───────┘                             └───────┬───────┘            │
│         │ SMF (tcp)                                    │ token endpoint     │
│         │                                              │ (https)           │
└─────────┼──────────────────────────────────────────────┼──────────────────┘
          │                                              │
          ▼                                              ▼
   Go test process                                Go test process
   (connect + publish)                            (acquire token)
```

### Step-by-step implementation

#### S1. Create Keycloak realm JSON

**File: `go-solace-sdk/internal/testutil/testdata/keycloak-realm.json`**

Pre-configured realm export with:
- Realm name: `solace`
- Client: `solace-test-client` with `client_credentials` grant enabled, client secret `test-secret`
- Default scope: `solace:publish`

This file is checked into the repo. Generate it once by:
1. Starting Keycloak (`docker run -p 8080:8080 -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin quay.io/keycloak/keycloak:26.2 start-dev`)
2. Creating the realm, client, and scope via the admin console
3. Exporting the realm JSON via admin console → Realm Settings → Partial Export (include clients, roles)

#### S2. Create TLS cert generation helper

**File: `go-solace-sdk/internal/testutil/tls.go`**

A Go function that generates a self-signed CA + server certificate at test time:

```go
func GenerateTLSCert(hosts ...string) (certPEM, keyPEM, caPEM []byte, err error)
```

- Generates an in-memory CA
- Issues a server cert with SANs for the provided hostnames (e.g., `keycloak`, `localhost`)
- Returns PEM-encoded cert, key, and CA cert
- No files on disk — everything stays in memory and gets written to container mounts via testcontainers

This avoids checking in certs or running shell scripts.

#### S3. Create Keycloak testcontainer helper

**File: `go-solace-sdk/internal/testutil/keycloak_container.go`**

```go
type KeycloakContainer struct {
    Container     testcontainers.Container
    Host          string
    HTTPSPort     string
    InternalHost  string  // hostname inside Docker network (e.g., "keycloak")
    ClientID      string
    ClientSecret  string
    Realm         string
}

func (kc *KeycloakContainer) TokenEndpoint() string
func (kc *KeycloakContainer) InternalDiscoveryURL() string
func (kc *KeycloakContainer) InternalJWKSURL() string

func StartKeycloakContainer(t *testing.T, network *testcontainers.DockerNetwork, certPEM, keyPEM []byte) *KeycloakContainer
```

Container setup:
- Image: `quay.io/keycloak/keycloak:26.2`
- Command: `start-dev --import-realm --https-certificate-file=/opt/certs/tls.crt --https-certificate-key-file=/opt/certs/tls.key`
- Env: `KEYCLOAK_ADMIN=admin`, `KEYCLOAK_ADMIN_PASSWORD=admin`, **`KC_HOSTNAME=https://keycloak:8443`**, `KC_HOSTNAME_STRICT=false`
- Mounts: realm JSON from `testdata/`, TLS cert+key from in-memory generation (`FileMode: 0o644` — the container runs as a non-root user and cannot read 0o600)
- Network: shared Docker network with hostname alias `keycloak`
- Exposed ports: 8443 (HTTPS)
- Wait: `wait.ForHTTP("/realms/solace").WithPort("8443/tcp").WithTLS(true).WithAllowInsecure(true)`

**Implementation notes (discovered during S6):**

- **`KC_HOSTNAME` is mandatory.** Without it, Keycloak derives the `iss` claim from the request URL (`https://localhost:<mapped-port>/realms/solace`) and the Solace broker — which did OIDC discovery against the internal URL — will reject tokens with an issuer mismatch. Pinning `KC_HOSTNAME=https://keycloak:8443` makes `iss` deterministic regardless of how the client reaches the token endpoint.
- **Key file must be world-readable.** Keycloak's process user cannot read a `0o600` key file mounted via `ContainerFile`; use `0o644`.

#### S4. Update SolaceContainer to support Docker networks

**File: `go-solace-sdk/internal/testutil/solace_container.go`**

Add a new constructor variant:

```go
func StartSolaceContainerOnNetwork(t *testing.T, network *testcontainers.DockerNetwork) *SolaceContainer
```

Same as existing `StartSolaceContainer` but:

- Attaches to the provided Docker network
- Sets a hostname alias (e.g., `solace-broker`)
- Exposes **`55443/tcp`** (secure SMF) in addition to 55555/8008/8080, and maps it in the returned struct via a new `SMFTLSPort` field + `SecureSMFAddress()` method

The existing `StartSolaceContainer` / `StartSolaceContainerE` remain unchanged — basic auth tests are not affected.

**Implementation notes (discovered during S6):**

- **Solace requires TLS for OAuth2.** The broker refuses OAuth2 auth on plain TCP sessions with `OAuth2 Authentication is not supported on unsecured sessions`. The test must connect over `tcps://` via `SecureSMFAddress()`.
- **Port 55443 does not listen by default.** Solace Standard doesn't enable TLS SMF out of the box — the port is exposed but the listener only comes up after a server certificate is installed (see S5). Do **not** add `wait.ForListeningPort(smfTLSPort)` to the container startup waits; it will time out.
- **SEMP/SMF port readiness ≠ message-spool readiness.** `wait.ForListeningPort` returns as soon as the ports accept TCP, but `POST /msgVpns/default/queues` still rejects with `MESSAGE_SPOOL_DATA_NOT_AVAILABLE` for ~5-15s afterwards. Tests must call the new `WaitForMessageSpool(t, timeout)` helper (which probes by creating and deleting a throwaway queue) before any queue/subscription SEMP calls.

#### S5. Add SEMP helpers for OAuth profile provisioning

**File: `go-solace-sdk/internal/testutil/solace_container.go`** (extend existing)

Add methods to `SolaceContainer`:

```go
// ImportDomainCertAuthority imports a CA certificate so the broker trusts Keycloak's TLS cert.
func (sc *SolaceContainer) ImportDomainCertAuthority(t *testing.T, name string, certPEM []byte)

// CreateOAuthProfile creates and enables an OAuth profile on the default VPN.
func (sc *SolaceContainer) CreateOAuthProfile(t *testing.T, cfg OAuthProfileConfig)

// EnableVPNOAuth enables OAuth authentication on the VPN and sets the default profile.
func (sc *SolaceContainer) EnableVPNOAuth(t *testing.T, profileName string)

// ConfigureServerTLS installs a server cert (combined PEM: cert || key) via
// PATCH /SEMP/v2/config/ so the broker accepts TLS on port 55443.
func (sc *SolaceContainer) ConfigureServerTLS(t *testing.T, certPEM, keyPEM []byte)

// WaitForTLSPort polls the broker's 55443 port until a TLS handshake succeeds.
func (sc *SolaceContainer) WaitForTLSPort(t *testing.T, timeout time.Duration)

// WaitForMessageSpool polls the broker until the message spool is operational.
func (sc *SolaceContainer) WaitForMessageSpool(t *testing.T, timeout time.Duration)

// CreateClientUsername creates and enables a client username on the default VPN.
func (sc *SolaceContainer) CreateClientUsername(t *testing.T, username string)
```

Where:

```go
type OAuthProfileConfig struct {
    ProfileName   string
    Role          string  // "resource-server" or "client"
    DiscoveryURL  string  // Keycloak's .well-known URL (internal Docker hostname)
    JWKSURL       string  // Keycloak's JWKS URL (internal Docker hostname)
    UsernameClaim string  // "azp" for Keycloak service accounts (see notes)
    ClientID      string  // client credentials used by the broker for introspection
    ClientSecret  string
}
```

These use the existing `sempPost` helper and also a new `sempPatch` for the VPN update and server-cert install.

**Implementation notes (discovered during S6):**

- **Broker calls the introspection endpoint.** Even with `resourceServerParseAccessTokenEnabled=true` (local JWT parsing), the broker also calls the IdP's introspection endpoint to verify the token is still active. That call needs `clientId`/`clientSecret` on the OAuth profile; without them, Keycloak returns 401 on introspect and the whole auth fails. The `OAuthProfileConfig` therefore includes `ClientID`/`ClientSecret`.
- **Default validation flags are strict.** `CreateOAuthProfile` must explicitly set:
  - `resourceServerValidateTypeEnabled: false` — default `true` requires `typ=at+jwt`; Keycloak emits `typ=Bearer`.
  - `resourceServerValidateAudienceEnabled: false` — client-credentials tokens from Keycloak do not carry `aud`.
  - `resourceServerValidateScopeEnabled: false` — profile has no required scope configured.
  - `resourceServerValidateIssuerEnabled: false` — broker's operational issuer (from discovery) should match the token's `iss` once `KC_HOSTNAME` is pinned, but keeping this off simplifies the test.
- **Username claim is `azp`, not `sub`.** Keycloak's `sub` for a service account is an opaque UUID per install; `azp` contains the static `client_id` (`solace-test-client`). `preferred_username` isn't emitted for service accounts by default.
- **A matching client username must pre-exist on the broker.** Even after a valid JWT, the broker denies the connection unless a client username equal to the extracted claim value is enabled on the VPN. Hence `CreateClientUsername(t, kc.ClientID)`.
- **TLS key for `ConfigureServerTLS` is PEM: cert concatenated with key**, passed in `tlsServerCertContent` via `PATCH /SEMP/v2/config/`.

#### S6. Write the integration test

**File: `go-solace-sdk/client_integration_test.go`**

```go
//go:build integration

func TestOAuth2ConnectAndPublish(t *testing.T) {
    ctx := context.Background()

    // 1. Generate TLS certs for Keycloak (SANs: keycloak, localhost)
    keycloakCertPEM, keycloakKeyPEM, keycloakCAPEM, err := testutil.GenerateTLSCert("keycloak", "localhost")
    require.NoError(t, err)

    // 2. Shared Docker network
    nw, err := tcnetwork.New(ctx)
    require.NoError(t, err)
    t.Cleanup(func() { _ = nw.Remove(ctx) })

    // 3. Keycloak with realm import (KC_HOSTNAME pinned so `iss` is stable)
    kc := testutil.StartKeycloakContainer(t, nw, keycloakCertPEM, keycloakKeyPEM)

    // 4. Solace on same network; wait for spool before any SEMP calls
    sc := testutil.StartSolaceContainerOnNetwork(t, nw)
    sc.WaitForMessageSpool(t, 60*time.Second)

    // 5. Install broker server cert and wait for TLS SMF to come up
    solaceCertPEM, solaceKeyPEM, _, err := testutil.GenerateTLSCert("solace-broker", "localhost", "127.0.0.1")
    require.NoError(t, err)
    sc.ConfigureServerTLS(t, solaceCertPEM, solaceKeyPEM)
    sc.WaitForTLSPort(t, 60*time.Second)

    // 6. Configure broker to trust Keycloak and validate tokens from it
    sc.ImportDomainCertAuthority(t, "keycloak-ca", keycloakCAPEM)
    sc.CreateOAuthProfile(t, testutil.OAuthProfileConfig{
        ProfileName:   "keycloak",
        Role:          "resource-server",
        DiscoveryURL:  kc.InternalDiscoveryURL(),
        JWKSURL:       kc.InternalJWKSURL(),
        UsernameClaim: "azp",
        ClientID:      kc.ClientID,
        ClientSecret:  kc.ClientSecret,
    })
    sc.EnableVPNOAuth(t, "keycloak")
    sc.CreateClientUsername(t, kc.ClientID) // must match the `azp` value

    // 7. Queue to capture the publish (hyphen-separated — SEMP path breaks on slashes)
    queue := "test-oauth2-queue"
    topic := "test/oauth2/publish"
    sc.CreateQueue(t, queue)
    sc.AddQueueSubscription(t, queue, topic)

    // 8. HTTP client that trusts Keycloak's self-signed cert for token acquisition
    httpClient := &http.Client{
        Transport: &http.Transport{
            TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // test cert
        },
        Timeout: 30 * time.Second,
    }

    // 9. Connect over tcps:// (OAuth2 requires TLS) with cert validation off
    client, err := solace.NewClient(sc.SecureSMFAddress(), sc.VPN,
        solace.WithOAuth2(kc.ClientID, kc.ClientSecret, kc.TokenEndpoint(), "solace:publish"),
        solace.WithHTTPClient(httpClient),
        solace.WithTLS(false, false),
    )
    require.NoError(t, err)
    require.NoError(t, client.Connect(ctx))
    t.Cleanup(func() { _ = client.Close() })

    // 10. Publish confirmed + verify arrival
    pub, err := producer.NewTopicPublisher(client)
    require.NoError(t, err)
    require.NoError(t, pub.Start(ctx))
    t.Cleanup(func() { _ = pub.Close() })

    msg := solace.NewMessage(topic, []byte(`{"test":"oauth2"}`))
    require.NoError(t, pub.PublishMessageConfirmed(ctx, msg))

    time.Sleep(500 * time.Millisecond)
    assert.Equal(t, 1, sc.GetQueueDepth(t, queue))
}
```

**SDK changes required by this test (new public API):**

- `solace.WithHTTPClient(*http.Client)` — overrides the HTTP client used for OAuth2 token acquisition. Needed here to accept Keycloak's self-signed cert. Optional in production; default is `&http.Client{Timeout: 30s}`. Named generically (not `WithOAuth2HTTPClient`) because the SDK has no other HTTP calls today but the option is forward-compatible if that changes.

**Implementation notes (discovered during S6):**

- **Queue names cannot contain `/`.** SEMP paths like `/SEMP/v2/config/msgVpns/default/queues/<name>/subscriptions` interpret slashes as path separators. Use hyphens (topic names are fine — they're in the body, not the URL). Existing producer integration tests already follow this convention.
- **Self-signed cert for the token endpoint requires `WithHTTPClient`.** Without it, the SDK's default `http.Client` rejects Keycloak's TLS cert and token acquisition fails before the broker is even contacted.

### Risks and mitigation

| Risk | Mitigation |
|------|------------|
| Keycloak startup is slow (~15-20s) | Accept the cost — this test runs in a separate `TestMain` or uses `t.Parallel()`. Keycloak only starts once per test suite. |
| Solace Standard might not support OAuth profiles via SEMP | The SEMP v2 API docs list `authenticationOauthProfiles` for Standard edition. If it fails, we'll discover it immediately in the first test run. |
| TLS cert generation adds complexity | The `GenerateTLSCert` helper is ~50 lines of standard `crypto/x509` code and is reusable across test suites. |
| Docker network adds testcontainers-go complexity | `testcontainers.GenericNetwork` is well-supported in v0.41.0. No new dependencies. |

### Existing tests are NOT affected

- `StartSolaceContainer` / `StartSolaceContainerE` remain unchanged
- `producer/topic_publisher_integration_test.go` continues using basic auth
- The OAuth2 test lives in a separate file with its own `TestMain` or uses the `t.Run` pattern with per-test container setup

---

## Event Publisher Integration Tests

**No changes needed.** Once the SDK has E2E coverage proving OAuth2 works against a real broker, the event-publisher integration tests can continue using basic auth. The event-publisher's only responsibility is passing the right `ConnectionOption` based on `auth_scheme` — that's covered by the config validation unit tests (Step 7) and by the SDK's new integration test.

---

## Execution Order

### Phase A: go-solace-sdk (do first)

1. `S1` — Create Keycloak realm JSON (manual one-time export)
2. `S2` — `GenerateTLSCert` helper
3. `S3` — `StartKeycloakContainer` helper
4. `S4` — `StartSolaceContainerOnNetwork` variant
5. `S5` — SEMP helpers for OAuth profile
6. `S6` — `TestOAuth2ConnectAndPublish` integration test
7. Release new SDK version (or update pseudo-version in event-publisher)

### Phase B: event-publisher (after SDK is proven)

**Prerequisite (do first):** bump the go-solace-sdk dependency in `event-publisher/go.mod` to **≥ commit `63525b5`** (the Phase A commit on `main`) — this pulls in the OAuth2 E2E test coverage and the new `solace.WithHTTPClient` option. All Phase B work below assumes this bump is already in place, so do it before touching any event-publisher code:

```sh
cd event-publisher
go get github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-gosolacesdk@main
go mod tidy
```

Then:

1. Steps 1-7 from the event-publisher plan above
2. `make lint && go test -tags=integration ./...`

**TLS in the target k8s deployment — no client-side cert handling required:**

- **Solace broker (SMF over `tcps://`):** the SDK's default is `WithTLS(false, false)` — cert and date validation off. The client accepts whatever cert the broker presents. No trust-store or `WithTLS(...)` call needed in Phase B.
- **IdP (OAuth2 token endpoint):** the SDK's default `http.Client` uses the pod's system trust store. In-cluster Keycloak (or a public-CA-signed IdP) is validated automatically. `solace.WithHTTPClient` is the escape hatch only if the IdP presents a cert the trust store rejects (self-signed, private CA not rolled into the pod image) — not the case for the production deployment.

Bottom line: Phase B code changes are purely config-plumbing. No TLS setup, no `WithHTTPClient`, no `WithTLS` call is needed.

---

## Checklist

### go-solace-sdk
- [x] Create `internal/testutil/testdata/keycloak-realm.json` (manual Keycloak export)
- [x] Add `GenerateTLSCert` helper (`internal/testutil/tls.go`)
- [x] Add `StartKeycloakContainer` helper (`internal/testutil/keycloak_container.go`)
- [x] Add `StartSolaceContainerOnNetwork` variant (`internal/testutil/solace_container.go`)
- [x] Add SEMP OAuth profile helpers (`ImportDomainCertAuthority`, `CreateOAuthProfile`, `EnableVPNOAuth`)
- [x] Add broker TLS provisioning (`ConfigureServerTLS`, `WaitForTLSPort`), message-spool wait (`WaitForMessageSpool`), and client-username helper (`CreateClientUsername`) — discovered necessary during implementation (see notes in S4/S5)
- [x] Write `TestOAuth2ConnectAndPublish` integration test (`client_integration_test.go`)
- [x] Run `make test-integration` — all existing + new tests pass

### event-publisher

- [ ] **Prerequisite:** bump `github.com/sonaemc-instore/lac1041-instoreorchestrator_esl-gosolacesdk` in `go.mod` to ≥ commit `63525b5` (Phase A on `main`, pushed 2026-04-23) via `go get ...@main && go mod tidy`
- [ ] Add `AuthScheme`, `ClientID`, `ClientSecret`, `TokenEndpoint`, `Scope` to `SolaceConfig` (config.go)
- [ ] Add same fields to `solace.Config` (client.go)
- [ ] Update `ToClientConfig()` to pass new fields
- [ ] Update `Validate()` with scheme-aware logic
- [ ] Update `NewClient()` to switch on auth scheme
- [ ] Update `config.yaml` with all new fields (commented defaults)
- [ ] Add config validation unit tests for both auth schemes
- [ ] Update go-solace-sdk pseudo-version in `go.mod`
- [ ] Run `make lint && go test -tags=integration ./...`
