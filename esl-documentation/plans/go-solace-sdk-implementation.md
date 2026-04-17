# Go Solace SDK - Implementation Plan

## Context

We're building a Go SDK for Solace PubSub+ that mirrors the functionality of three .NET SDK repositories (core, consumer, producer) from `MCDigital.EDAP.Solace`. The .NET SDK provides connection management, queue/topic consumer with explicit settlement, topic/queue producer with retry and ACK confirmation, OAuth2 auth, and full OpenTelemetry instrumentation. This Go SDK will be a single Go module with idiomatic Go patterns.

**Module path:** `github.com/sonaemc-instore/lac1041-instoreorchestrator_go-solace-sdk`

## Module & Package Structure

```
go-solace-sdk/
  go.mod                              // module github.com/sonaemc-instore/lac1041-instoreorchestrator_go-solace-sdk
  go.sum

  // ---- Root package: solace ----
  solace.go                           // package solace -- top-level doc
  options.go                          // ConnectionOption functional options
  client.go                           // Client (connection owner, state machine, health)
  message.go                          // Message struct, DeliveryMode, NewMessage()
  topic.go                            // Topic struct, TopicBuilder, Parse, Validate
  errors.go                           // ErrConnection, ErrMessaging, ErrConfirmationTimeout
  health.go                           // HealthStatus, HealthResult
  state.go                            // ConnectionState type alias + re-exported constants from internal/state

  // ---- Consumer package ----
  consumer/
    consumer.go                       // package doc
    queue_consumer.go                 // QueueConsumer: flow lifecycle, settlement, recovery
    topic_subscriber.go               // TopicSubscriber: direct messaging, wildcard match
    handler.go                        // HandlerFunc, HandlerRegistration, handler manager
    options.go                        // ConsumerOption functional options
    settlement.go                     // NackType enum (Failed, Rejected)

  // ---- Producer package ----
  producer/
    producer.go                       // package doc
    topic_publisher.go                // TopicPublisher: Publish + PublishConfirmed
    options.go                        // ProducerOption functional options
    retry.go                          // Retry loop with exponential backoff
    message.go                        // solace.Message -> OutboundMessage conversion

  // ---- Internal packages ----
  internal/
    state/
      state.go                        // ConnectionState type + constants (shared to avoid import cycles)
    auth/
      oauth.go                        // OAuth2 token manager + proactive refresh goroutine
    conn/
      state_controller.go             // Atomic state machine (CAS-based transitions, uses internal/state)
      session_lifecycle.go            // Session build/connect/disconnect (wraps solace.dev/go/messaging)
      session_events.go               // Maps Solace events to ConnectionState transitions
    telemetry/
      tracing.go                      // W3C trace context inject/extract
      metrics_core.go                 // Connection metrics
      metrics_consumer.go             // Consumer metrics
      metrics_producer.go             // Producer metrics
      constants.go                    // Metric/span name constants
    topic/
      matcher.go                      // Wildcard topic matching (* and >)
    testutil/
      solace_container.go             // Testcontainers helper for Solace PubSub+
```

## Key Public API

### Root package (`solace`)

```go
// Client owns the connection and is passed to consumers/producers.
// host and vpn are required constructor args; auth is required via options.
type Client struct { ... }
func NewClient(host, vpn string, opts ...ConnectionOption) (*Client, error)
func (c *Client) Connect(ctx context.Context) error
func (c *Client) Disconnect(ctx context.Context) error
func (c *Client) Close() error
func (c *Client) State() ConnectionState
func (c *Client) IsConnected() bool
func (c *Client) Health() HealthResult
func (c *Client) OnStateChange(fn func(ConnectionState))
func (c *Client) OnFault(fn func(error))

// Authentication (exactly one required -- validated at construction)
func WithBasicAuth(username, password string) ConnectionOption
func WithOAuth2(clientID, clientSecret, tokenEndpoint, scope string) ConnectionOption

// Optional with defaults (matching .NET SDK defaults)
func WithReconnect(retries int, wait time.Duration) ConnectionOption         // default: 3 retries, 2s wait
func WithConnectTimeout(d time.Duration) ConnectionOption                    // default: 10s (min 1s)
func WithConnectRetries(n int) ConnectionOption                              // default: 3 (min 0)
func WithKeepAlive(d time.Duration) ConnectionOption                         // default: 30s
func WithTLS(validateCert, validateDate bool) ConnectionOption               // default: false, false
func WithGuaranteedDelivery(enabled bool) ConnectionOption                   // default: true
func WithSendBlocking(blocking bool) ConnectionOption                        // default: true
func WithTokenExpiryBuffer(d time.Duration) ConnectionOption                 // default: 60s (OAuth only)
func WithTracerProvider(tp trace.TracerProvider) ConnectionOption
func WithMeterProvider(mp metric.MeterProvider) ConnectionOption
func WithLogger(logger *slog.Logger) ConnectionOption                        // default: slog.Default()

// Message -- concrete struct (not interface)
type Message struct {
    Destination      string
    Payload          []byte
    DeliveryMode     DeliveryMode
    CorrelationID    string
    PartitionKey     string
    DMQEligible      bool
    Properties       map[string]string
}

// Topic -- structured with validation
type Topic struct { ApplicationDomain, DataDomain, ObjectType, Verb, Version string; Properties []string }
func ParseTopic(s string) (Topic, error)
func NewTopicBuilder() *TopicBuilder
```

### Consumer package

```go
type HandlerFunc func(ctx context.Context, msg *solace.Message) error

// QueueConsumer -- guaranteed delivery with explicit settlement
func NewQueueConsumer(client *solace.Client, queue string, opts ...ConsumerOption) (*QueueConsumer, error)
func (qc *QueueConsumer) Start(ctx context.Context) error
func (qc *QueueConsumer) Stop(ctx context.Context) error      // 3-phase graceful shutdown
func (qc *QueueConsumer) AddHandler(fn HandlerFunc) *HandlerRegistration
func (qc *QueueConsumer) RemoveHandler(reg *HandlerRegistration)
func (qc *QueueConsumer) Acknowledge(msg *solace.Message) error
func (qc *QueueConsumer) Reject(msg *solace.Message, nackType NackType) error
func (qc *QueueConsumer) Close() error

// TopicSubscriber -- direct messaging with wildcards
func NewTopicSubscriber(client *solace.Client, topicExpr string, opts ...ConsumerOption) (*TopicSubscriber, error)
func (ts *TopicSubscriber) AddHandler(fn HandlerFunc) *HandlerRegistration
func (ts *TopicSubscriber) RemoveHandler(reg *HandlerRegistration)
func (ts *TopicSubscriber) Close() error
```

### Producer package

```go
// TopicPublisher -- publishes messages to Solace topics.
// Supports two modes:
//   - Fixed topic: set via WithTopic, used by Publish/PublishConfirmed
//   - Dynamic topic: set per message via msg.Destination, used by PublishMessage/PublishMessageConfirmed
func NewTopicPublisher(client *solace.Client, opts ...Option) (*TopicPublisher, error)
func (tp *TopicPublisher) Start(ctx context.Context) error                             // creates internal Solace publishers
func (tp *TopicPublisher) Publish(ctx context.Context, payload []byte) error           // fixed topic, direct
func (tp *TopicPublisher) PublishMessage(ctx context.Context, msg *solace.Message) error // dynamic topic, direct
func (tp *TopicPublisher) PublishConfirmed(ctx context.Context, payload []byte) error  // fixed topic, persistent + ACK
func (tp *TopicPublisher) PublishMessageConfirmed(ctx context.Context, msg *solace.Message) error // dynamic topic, persistent + ACK
func (tp *TopicPublisher) Close() error

// Options
func WithTopic(topic string) Option                                                    // fixed destination topic (optional)
func WithRetryPolicy(maxAttempts int, baseDelay time.Duration, exponential bool) Option
func WithConfirmationTimeout(d time.Duration) Option
func WithDMQEligible(eligible bool) Option
func WithBackPressureSize(size uint) Option
func WithTerminateGrace(d time.Duration) Option
```

> **No QueueProducer:** The Solace Go library follows Solace's recommended pattern where
> publishers always publish to topics. Queues receive messages via topic subscriptions
> (topic-to-queue mapping), configured on the broker. This decouples producers from
> infrastructure and enables flexible fan-out. See the .NET `QueueProducer` mapping in
> the table below and the README's "Publishing to Queues" section for migration guidance.

## .NET to Go Mapping Decisions

| .NET Pattern | Go Equivalent | Rationale |
|---|---|---|
| `IDisposable` | `Close() error` | `io.Closer` convention |
| DI / `IOptions<T>` | Functional options | `NewX(opts ...Option)` idiom |
| Events (`EventHandler<T>`) | Callbacks `OnX(func(...))` | No channel leaks |
| `CancellationToken` | `context.Context` | First param on all blocking methods |
| `async/await` / `Task<T>` | Blocking calls + goroutines | Go concurrency model |
| `SemaphoreSlim` | `sync.Mutex` | Simpler, sufficient |
| `ConcurrentDictionary` + `TaskCompletionSource` (AckTracker) | `PersistentMessagePublisher.PublishAwaitAcknowledgement()` | Go Solace library handles ACK correlation internally |
| Polly retry | Custom for-loop + `time.Timer` | No external dependency needed |
| `ActivitySource` / `Activity` | `trace.Tracer` / `trace.Span` | Direct OTel mapping |
| `Meter` / Counters | `metric.Meter` / instruments | Direct OTel mapping |
| `ILogger` | `*slog.Logger` | Go 1.21+ stdlib; SDK is backend-agnostic, consuming apps choose their own slog handler (e.g. zap via `zapslog`) |
| `ISolaceMessage` interface | Concrete `Message` struct | Go prefers concrete types |
| `ISolaceMessageFactory` | **Drop** | `NewMessage()` or struct literal |
| `ISessionAccessor` | Unexported method on `Client` | Internal access only |
| `IHostedService` | **Drop** | Background goroutine instead |
| `ServiceCollectionExtensions` | **Drop** | No DI container |
| `MessageSerializer` | **Drop** | Users handle JSON/protobuf |
| `QueueProducer` (direct-to-queue) | **Drop** — use `TopicPublisher` + topic-to-queue mapping | Go Solace library only supports topic-based publishing; Solace best practice is to decouple producers from queue infrastructure |

## Phased Build Order

### Phase 1 -- Foundation (no Solace dependency needed for tests)
Files:
- `go.mod` -- module init with Go 1.26
- `errors.go` -- `ErrConnection`, `ErrMessaging`, `ErrConfirmationTimeout`
- `state.go` -- `ConnectionState` enum + `String()`
- `health.go` -- `HealthStatus`, `HealthResult`
- `message.go` -- `Message` struct, `DeliveryMode`, `NewMessage()`
- `topic.go` -- `Topic`, `TopicBuilder`, `ParseTopic`, `Validate` with segment regex
- `internal/topic/matcher.go` -- wildcard matching (`*` and `>`)
- `internal/conn/state_controller.go` -- atomic state machine with `atomic.Int32`
- Unit tests for all above using `testify` v1.11.1 (`assert` + `require`)
- Update `README.md`, `CLAUDE.md`, and this plan to reflect any decisions made during implementation

### Phase 2 -- Telemetry
Files:
- `internal/telemetry/constants.go` -- meter/tracer/attribute names
- `internal/telemetry/metrics_core.go` -- connection counters/histograms/gauges
- `internal/telemetry/metrics_consumer.go` -- consumer instruments
- `internal/telemetry/metrics_producer.go` -- producer instruments
- `internal/telemetry/tracing.go` -- W3C trace context inject/extract
- Tests with OTel SDK test exporters
- Update `README.md`, `CLAUDE.md`, and this plan to reflect any decisions made during implementation

### Phase 3 -- Connection Management
Files:
- `internal/auth/oauth.go` -- OAuth2 client_credentials + refresh + proactive goroutine
- `internal/conn/session_lifecycle.go` -- wraps `solace.dev/go/messaging` MessagingService
- `internal/conn/session_events.go` -- event-to-state mapping
- `options.go` -- all `ConnectionOption` funcs
- `client.go` -- `Client` struct wiring everything together
- `internal/testutil/solace_container.go` -- shared Testcontainers helper (spins up `solace/solace-pubsub-standard:latest`)
- Integration tests using Testcontainers v0.41.0 (self-contained, no external Docker Compose needed)
- Update `README.md`, `CLAUDE.md`, and this plan to reflect any decisions made during implementation

### Phase 4 -- Producer

Files:

- `producer/options.go` -- `ProducerOption` funcs (retry policy, confirmation timeout, DMQ eligibility)
- `producer/retry.go` -- retry loop with exponential backoff + transient error classification
- `producer/message.go` -- conversion from `solace.Message` to Solace `OutboundMessage` via `OutboundMessageBuilder`
- `producer/topic_publisher.go` -- TopicPublisher with two internal Solace publishers:
  - `DirectMessagePublisher` for `Publish()` / `PublishMessage()` (fire-and-forget)
  - `PersistentMessagePublisher` for `PublishConfirmed()` / `PublishMessageConfirmed()` (persistent + ACK via `PublishAwaitAcknowledgement`)
  - Manages lifecycle (`Start`/`Terminate`) of both internal publishers
  - Tracing via `telemetry.StartProducerSpan` + `InjectTraceContext`; metrics via `ProducerMetrics`
- `producer/producer.go` -- package doc
- Unit tests + integration tests
- Update `README.md`, `CLAUDE.md`, and this plan to reflect any decisions made during implementation

No QueueProducer: The Go Solace library only supports topic-based publishing. Queues receive
messages via topic subscriptions (topic-to-queue mapping), configured on the broker. This is
Solace's recommended best practice — it decouples producers from queue infrastructure and enables
flexible fan-out. Users who need messages to land in a queue should publish to a topic and
configure the queue to subscribe to that topic. The README will include a "Publishing to Queues"
section with migration guidance for users coming from the .NET SDK.

Solace Go API notes for Phase 4:

- **No AckTracker needed**: `PersistentMessagePublisher.PublishAwaitAcknowledgement()` handles ACK correlation, timeout, and NACK internally
- **No QueueProducer**: Dropped in favor of topic-to-queue mapping (Solace best practice)
- **Two publisher types**: `DirectMessagePublisher` (non-persistent) and `PersistentMessagePublisher` (guaranteed delivery) — TopicPublisher needs both
- **Destination type**: All publish methods accept `*resource.Topic` — this is by design in the Go Solace library
- **Message conversion**: Our `solace.Message` struct must be converted to `OutboundMessage` via `MessagingService.MessageBuilder()`, mapping CorrelationID, DMQEligible, PartitionKey, Properties to builder methods and `config.MessageProperty*` constants
- **Publisher lifecycle**: Both Solace publisher types require explicit `Start()` before publishing and `Terminate(gracePeriod)` on cleanup
- **Review producer metrics**: Some metrics in `internal/telemetry/metrics_producer.go` were ported from the .NET SDK and may not apply now that AckTracker is removed and the Go Solace library handles ACK internally (e.g., `AckNacks`, `AckInflight`, `PublishBlocked`). Review which metrics are still observable from our code vs. handled internally by the library

Phase 4 implementation decisions (2026-03-30):

- **Dynamic and fixed topic modes**: `NewTopicPublisher(client, opts...)` no longer requires a topic at construction. `WithTopic(topic)` sets a fixed destination for `Publish`/`PublishConfirmed`. Without it, the publisher operates in dynamic-topic mode where `msg.Destination` is used per-publish via `PublishMessage`/`PublishMessageConfirmed`. The `*resource.Topic` is created at publish time from the resolved string — no cached destination field.
- **Option type renamed**: `ProducerOption` renamed to `Option` to avoid `producer.ProducerOption` stutter (Go naming convention, flagged by `revive` linter).
- **Partition key via SDK constant**: Uses `config.QueuePartitionKey` (`"JMSXGroupID"`) from the Solace Go SDK, matching the .NET SDK's `SOLCLIENT_USER_PROP_QUEUE_PARTITION_KEY`.
- **Metrics pruned**: Removed `PublishBlocked`, `AckTimeouts`, `AckNacks`, `SendLatency`, `AckLatency`, `AckInflight` — not observable from our code since the Go Solace library handles back-pressure, ACK correlation, and timing internally. Kept and wired: `PublishAttempts`, `PublishSuccesses`, `PublishFailures`, `AckConfirmed`, `RetryAttempts`, `RetryExhausted`, `PublishDuration`, `PayloadSize`.
- **Context-aware Start**: `Start(ctx)` uses `StartAsync()` + `select` on context to respect cancellation during publisher initialization.
- **Retry callbacks**: `executeWithRetry` accepts `retryCallbacks` with `onRetry(ctx)` and `onExhausted(ctx)` hooks, keeping retry logic decoupled from telemetry.

### Phase 5 -- Consumer (deferred to ESL Phase 3)

> **Deferred:** The consumer is not needed for ESL Phase 2 (CDC event publishing).
> It will be implemented as part of ESL Phase 3 when a consuming service is built.
> See `/Users/joaopires/Projects/personal/useful-stuff/esl-documentation/plans/phase3/solace-consumer.md`
> for the Phase 3 planning seed with open questions and context.

Files:
- `consumer/handler.go` -- `HandlerFunc`, `HandlerRegistration`, handler manager
- `consumer/settlement.go` -- `NackType`
- `consumer/options.go` -- `ConsumerOption` funcs
- `consumer/queue_consumer.go` -- flow lifecycle, 3-phase stop (stop intake, drain in-flight, dispose), settlement, recovery goroutine
- `consumer/topic_subscriber.go` -- direct receiver, wildcard dispatch
- `consumer/consumer.go` -- package doc
- Unit tests + integration tests
- Update `README.md`, `CLAUDE.md`, and this plan to reflect any decisions made during implementation

Phase 5 review notes:
- **Review `internal/topic/matcher.go`**: May be unnecessary if the Go Solace library's `DirectMessageReceiver` handles subscription matching natively (each receiver gets its own topic filter from the broker). Remove if redundant.
- **Review consumer metrics**: `internal/telemetry/metrics_consumer.go` was ported from the .NET SDK's `ConsumerMetrics.cs`. Verify these metrics make sense for the Go consumer's architecture before wiring them in — don't assume the .NET metric names are correct for how the Go consumer will work.

### Phase 6a -- Producer Polish (after Phase 4, before consumer) ✅

- Producer integration tests using Testcontainers:
  - Publish messages to Solace and verify they arrive correctly (use Solace SEMP API or a native Solace receiver in the test to inspect/consume from the queue)
  - Test both direct (`Publish`) and confirmed (`PublishConfirmed`) paths
  - Validate message properties, headers, delivery mode, and trace context propagation
- `examples/` directory with producer usage samples (connect + publish)
- `README.md` with:
  - Quick start guide (connect, publish)
  - "How Solace Messaging Works" section — topics as routing addresses, queues as storage, topic-to-queue mapping
  - "Publishing to Queues" section — explains that publishers publish to topics, queues subscribe to topics, and how to configure topic-to-queue mapping (broker UI, CLI, or programmatically)
  - API reference overview with links to godoc
- Review and update of `README.md`, `CLAUDE.md`, and this plan

Phase 6a implementation details (2026-03-30):

- **Integration tests** (`producer/topic_publisher_integration_test.go`): Build-tagged with `//go:build integration`, uses shared Testcontainers Solace instance across subtests. Tests: DirectPublish, DirectPublishMessage, ConfirmedPublish (queue depth via SEMP), ConfirmedPublishBatch, ConfirmedPublishMessageWithProperties, TraceContextPropagation (OTel span verification), DirectPublishTracing, PublisherLifecycle (double-close safety).
- **SEMP helpers** added to `internal/testutil/solace_container.go`: `CreateQueue`, `AddQueueSubscription`, `GetQueueDepth` (SEMP v2 config + monitor APIs). SEMPPort exposed on `SolaceContainer`.
- **Makefile**: Added `test-integration` target (`go test -tags integration -timeout 300s`).
- **Example** (`examples/producer/main.go`): Connects with basic auth, demonstrates both `Publish` (direct) and `PublishMessageConfirmed` (persistent + ACK) with correlation ID and properties. Configurable via environment variables.
- **README.md**: Full rewrite — quick start with producer, "How Solace Messaging Works" (topics, queues, topic-to-queue mapping, delivery modes, wildcards), "Publishing to Queues" (CLI, SEMP, UI examples), API reference for Client, Message, Topic, TopicPublisher, telemetry (metrics table + tracing attributes).

### Phase 6b -- Consumer Polish (deferred to ESL Phase 3, after Phase 5)

- End-to-end integration tests (producer -> queue -> consumer round trip using our SDK on both sides)
- `examples/` directory updated with consumer usage samples (subscribe, consume, ACK/NACK)
- `README.md` updated with:
  - Quick start guide expanded to include consume flow
  - ".NET SDK Migration" section — maps .NET QueueProducer to TopicPublisher + topic-to-queue mapping, with before/after code examples
- Final review and update of `README.md`, `CLAUDE.md`, and this plan

## Verification

1. **Unit tests**: `go test ./...` -- all phases have unit tests using `testify` v1.11.1
2. **Integration tests**: Use Testcontainers v0.41.0 (`solace/solace-pubsub-standard:latest`) — tests are self-contained, no external Docker Compose required
3. **Producer integration tests** (Phase 6a): Publish to Solace, verify messages arrive with correct properties using SEMP API or native receiver
4. **End-to-end** (Phase 6b): Producer publishes to queue, consumer receives, acknowledges; verify via metrics/traces
5. **Linting**: `golangci-lint run` -- standalone binary installed via curl (see `install-lint` Makefile target), NOT `go tool golangci-lint`

## Conventions

- **Errcheck suppression policy**: Never silently discard errors with `_, _ =` to satisfy errcheck. If suppression is warranted (e.g., `sync.Map` type assertions where types are internally guaranteed), add a scoped exclusion rule in `.golangci.yml` for the specific file AND document the rationale in the source code.
- **No magic strings**: Any string used in more than one place must be extracted to a named constant. No hardcoded or duplicated string literals — place shared constants in a common location so they are referenced, not repeated.
- **Import cycle prevention**: Shared types needed by both root `solace` and `internal/*` packages live in dedicated `internal/` packages (e.g., `internal/state`). Root package re-exports via type aliases (`type X = internal.X`).
- **Callback safety**: User-registered callbacks must be wrapped with panic recovery to prevent crashes from user code propagating into the SDK.
- **Thread safety**: Methods returning internal references (e.g., `MessagingService()`) must document lifetime constraints.
- **External dependencies**: Before writing any code that calls an external library API, always ask the user for the relevant documentation and which version to use. Never guess API shapes, search the module cache, or assume interface signatures. This applies to every phase of implementation, not just when adding new dependencies.
- **Integration tests use `TestMain`**: When integration tests share an expensive resource (e.g. a Testcontainers container), use `TestMain(m *testing.M)` for setup/teardown and a package-level variable to hold the shared resource. Each test must be an independent top-level `TestXxx` function, not a subtest under a parent. This ensures output streams in real time and tests can be run individually. Test helpers that need to work from `TestMain` must provide an error-returning variant (e.g. `StartSolaceContainerE`) since `*testing.T` is not available.

## Source .NET Repositories

The Go SDK is based on three private .NET repositories cloned locally:

| Repo | Local Path | Purpose |
|---|---|---|
| **Core** | `/Users/joaopires/Projects/sonae/go-solace-sdk/lac1043-dotnet_sdk-core/` | Connection management, message model, auth, telemetry, health |
| **Consumer** | `/Users/joaopires/Projects/sonae/go-solace-sdk/lac1043-dotnet_sdk-consumer/` | Queue consumer, topic subscriber, handler pipeline, settlement |
| **Producer** | `/Users/joaopires/Projects/sonae/go-solace-sdk/lac1043-dotnet_sdk-producer/` | Topic publisher, queue producer, retry policies, ACK confirmation |

### Key Reference Files

**Core** (`lac1043-dotnet_sdk-core/src/MCDigital.EDAP.Solace.Core/`):
- `Core/SolaceConnection.cs` -- Connection lifecycle, state machine, event processing
- `Internal/ConnectionStateController.cs` -- Atomic CAS-based state transitions
- `Core/AckTracker.cs` -- Pending ACK registration/completion
- `Authentication/OAuthTokenManager.cs` -- OAuth2 client_credentials + refresh token flow
- `Messaging/SolaceMessage.cs` -- Message abstraction (payload, properties, metadata)
- `Messaging/TopicBuilder.cs` -- Structured topic model with validation
- `Configuration/SolaceConnectionOptions.cs` -- Connection configuration model
- `Telemetry/CoreMetrics.cs` -- Connection metrics instrument definitions
- `Health/ISolaceHealthCheck.cs` -- Health check interface

**Consumer** (`lac1043-dotnet_sdk-consumer/src/MCDigital.EDAP.Solace.Consumer/`):
- `QueueConsumer/QueueConsumer.cs` -- Flow lifecycle, settlement, 3-phase shutdown, flow recovery
- `TopicSubscriber/TopicSubscriber.cs` -- Direct messaging, wildcard dispatch
- `TopicSubscriber/TopicMatcher.cs` -- Wildcard topic matching (* and >)
- `Subscription/SubscriptionToken.cs` -- Handler management and invocation
- `Messaging/MessageEventDispatcher.cs` -- Message processing pipeline
- `Telemetry/TraceContextPropagator.cs` -- W3C trace context extraction
- `Telemetry/ConsumerMetrics.cs` -- Consumer metric instruments

**Producer** (`lac1043-dotnet_sdk-producer/src/MCDigital.EDAP.Solace.Producer/`):
- `Messaging/SolaceMessageProducerBase.cs` -- Retry logic, ACK correlation, confirmation timeout
- `TopicPublisher/TopicPublisher.cs` -- Direct + confirmed topic publishing
- `QueueProducer/QueueProducer.cs` -- Persistent queue sending, auto-provisioning
- `Messaging/PollyPolicyFactory.cs` -- Retry policy construction (exponential backoff)
- `Exceptions/TransientExceptions.cs` -- Transient error classification
- `Telemetry/TraceContextPropagator.cs` -- W3C trace context injection
- `Telemetry/ProducerMetrics.cs` -- Producer metric instruments
- `Configuration/SolaceProducerOptions.cs` -- Producer + retry configuration
