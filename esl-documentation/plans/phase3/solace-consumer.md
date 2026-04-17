# Phase 3: Solace Consumer — Planning Seed

## Context

Phase 2 of the ESL CDC pipeline publishes entity change events (CREATED, MODIFIED) to Solace topics (`esl/events/{entity_type}`) using the Go Solace SDK's `TopicPublisher.PublishConfirmed()` with guaranteed delivery via the transactional outbox pattern.

Phase 3 introduces a **new Go component** that consumes these events from Solace. This document captures the context, decisions, and open questions needed to implement the consumer side of the Go Solace SDK (Phase 5 in the SDK implementation plan) and the consuming service itself.

## SDK State When This Was Written (2026-03-28)

- **Phases 1-3 done:** Foundation types, telemetry, connection management
- **Phase 4 (Producer) in progress:** TopicPublisher with direct + confirmed publishing
- **Phase 5 (Consumer) deferred:** QueueConsumer, TopicSubscriber, handler pipeline — not started
- **Phase 6 (Polish) deferred:** End-to-end tests, examples, full README

The SDK implementation plan with full Phase 5 details is at:
`/Users/joaopires/Projects/sonae/esl/go-solace-sdk/CLAUDE.md` (conventions) and
`/Users/joaopires/Projects/sonae/esl/plans/go-solace-sdk-implementation.md` (phased plan)

## What the SDK Plan Already Covers (Phase 5)

The SDK plan already defines the consumer API and files:

- `consumer/queue_consumer.go` — flow lifecycle, 3-phase shutdown, settlement, recovery
- `consumer/topic_subscriber.go` — direct receiver, wildcard dispatch
- `consumer/handler.go` — `HandlerFunc`, `HandlerRegistration`, handler manager
- `consumer/settlement.go` — `NackType` (Failed, Rejected)
- `consumer/options.go` — `ConsumerOption` functional options

Pre-built telemetry (needs review before wiring):
- `internal/telemetry/metrics_consumer.go` — ported from .NET, may need adjustment
- `internal/telemetry/tracing.go` — W3C trace context extract already implemented

## Open Questions for Phase 3

### About the consuming component

- **What component will consume from Solace?** A new Go service? An extension of an existing one?
- **What does it do with the events?** (e.g., update a read model, trigger workflows, forward to another system)
- **Deployment model?** Same K8s cluster as the event publisher? Separate namespace?

### About Solace consumption patterns

- **Queue-based (guaranteed) or topic subscription (direct)?**
  - Queue-based (`QueueConsumer`) gives guaranteed delivery, explicit ACK/NACK, and message persistence during downtime — likely what you want for CDC events
  - Topic subscription (`TopicSubscriber`) is fire-and-forget, no settlement — only suitable for non-critical notifications
  - You can use both if different event types have different reliability requirements
- **Queue name(s)?** What queue(s) will be provisioned on the Solace broker? (e.g., `esl/events/queue` subscribing to `esl/events/>`)
- **Topic subscription patterns?** Will the consumer subscribe to all entity types (`esl/events/>`) or specific ones (`esl/events/store`, `esl/events/label`)?
- **Concurrency model?** Single handler per message (sequential) or parallel processing? Max in-flight messages?

### About settlement and error handling

- **ACK strategy?** ACK after successful processing? Or ACK after writing to a local store?
- **NACK behavior?** On processing failure: reject (move to DMQ) or fail (redeliver)? After how many retries?
- **Poison message handling?** Max redelivery count before DMQ? (typically configured broker-side, but the consumer needs to be aware)
- **Idempotency?** CDC events from the outbox may be delivered more than once — does the consumer need deduplication?

### About the SDK implementation itself

- **Review `internal/topic/matcher.go`:** The SDK plan flags this for review. If the consumer only uses `QueueConsumer` (broker handles subscription matching), this code is unnecessary. If `TopicSubscriber` is also needed, verify whether the Go Solace library's `DirectMessageReceiver` handles matching natively before keeping it.
- **Review `internal/telemetry/metrics_consumer.go`:** Ported from .NET `ConsumerMetrics.cs`. Some metrics may not make sense for the Go consumer's architecture. Review before wiring.
- **Handler pipeline design:** The .NET SDK has `MessageEventDispatcher` with a processing pipeline. Decide if the Go consumer needs middleware-style handlers or if simple `HandlerFunc` callbacks are sufficient.

## .NET Reference for Consumer

The .NET consumer SDK is at `/Users/joaopires/Projects/sonae/go-solace-sdk/lac1043-dotnet_sdk-consumer/`. Key files:

- `QueueConsumer/QueueConsumer.cs` — flow lifecycle, settlement, 3-phase shutdown
- `TopicSubscriber/TopicSubscriber.cs` — direct messaging, wildcard dispatch
- `Subscription/SubscriptionToken.cs` — handler management
- `Messaging/MessageEventDispatcher.cs` — message processing pipeline
- `Telemetry/ConsumerMetrics.cs` — consumer metrics (review before porting)

Remember: the .NET SDK is a **domain reference** (instrumentation patterns, conventions, feature parity), NOT an API template. The Go SDK is a standalone product.

## Dependencies

Before implementing Phase 5, check:
- Go Solace library (`solace.dev/go/messaging`) docs for `PersistentMessageReceiver` and `DirectMessageReceiver` APIs
- Current version pinned in `go.mod` (v1.10.0 at time of writing)
- Ask for external dependency docs before coding (per SDK conventions)
