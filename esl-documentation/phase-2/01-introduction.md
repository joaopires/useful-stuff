---
title: "ESL Orchestrator"
subtitle: "Phase 2 — Technical Documentation"
author: "João Pires - Devoteam"
affiliation: "Sonae MC"
lang: "en"
---

```{=typst}
#show link: set text(fill: blue)
```

```{=typst}
#block(
  width: 100%,
  fill: rgb("#fdf3e7"),
  stroke: (left: 3pt + rgb("#d35400")),
  inset: (x: 14pt, y: 12pt),
  radius: 2pt,
)[
  #text(font: "Ubuntu", weight: "bold", size: 12pt, fill: rgb("#b34700"))[Critical operations notice — failover is manual]

  The ESL Orchestrator's publishing components — the datapipeline CronJob and the event-publisher Deployment — run in an *active/passive* configuration across two OpenShift clusters per environment. Only the active cluster publishes; the passive cluster is suspended.

  *Failover is not automatic.* If the active cluster becomes unhealthy, an operator must fail over manually by flipping the `activeCluster` value in the environment's values file and letting ArgoCD sync. Until that is done, no datapipeline runs and no events are published.

  Full procedure, verification, and rollback are in #link(<activepassive-failover>)[Section 7.7 — Active/Passive Failover].
]
```

# Introduction

## Purpose

This document provides the technical documentation for **Phase 2** of the ESL Orchestrator platform at Sonae MC. Building on the data synchronisation pipeline established in Phase 1, Phase 2 adds **Change Data Capture (CDC)** — the ability to detect when entity records are created, modified, or deleted during each pipeline execution and publish those changes as events to a Solace message broker.

Phase 2 delivers three new components and modifies one existing component:

| Component | Role |
|---|---|
| **esl-common** (new) | Shared Go library containing CDC event types and entity key definitions, imported by both the Data Pipeline and the Event Publisher |
| **Database — event outbox** (new migrations) | Transactional outbox table that stores detected change events atomically alongside data upserts |
| **Data Pipeline — CDC** (modified) | Pre-fetch and in-Go classification logic added to the existing sink, writing change events to the outbox within the same database transaction as upserts |
| **Event Publisher** (new) | Long-running service that polls the outbox table and publishes events to Solace with guaranteed delivery |

## Scope

This document covers the full Phase 2 scope: architecture, database changes, Data Pipeline CDC logic, Event Publisher service, deployment, and operations.

All three CDC event types are covered: CREATED, UPDATED, and DELETED. DELETED detection applies to products and labels only (stores and access points have no deletion lifecycle in Vusion).

## Audience

This document is intended for the same audience as Phase 1:

- **Technical stakeholders** who need to understand the CDC architecture and its integration with the existing platform
- **Developers** who will extend or maintain the CDC pipeline and Event Publisher
- **Operations teams** who will deploy, configure, and monitor the new components
- **Project managers and product owners** who need visibility into the platform's new capabilities

## How to Read This Document

The document is structured in the following order:

1. **System Architecture** — Updated high-level view showing how CDC fits into the existing platform
2. **Database** — Event outbox table, indexes, and retention
3. **Data Pipeline** — CDC detection logic in the sink
4. **Event Publisher** — Outbox polling and Solace publishing
5. **Deployment & Infrastructure** — Helm chart changes for the new components
6. **Operations & Maintenance** — Monitoring, outbox management, and troubleshooting

## Glossary

Terms introduced in Phase 1 still apply. The following terms are new in Phase 2:

| Term | Description |
|---|---|
| **CDC** | Change Data Capture — detecting and recording data changes as they occur |
| **Transactional Outbox** | Pattern where change events are written to a database table within the same transaction as the data change, guaranteeing atomicity |
| **Event Publisher** | Service that polls the outbox table and publishes events to a message broker |
| **Solace** | Message broker used for event distribution to downstream consumers |
| **Outbox** | The `event_outbox` table that acts as a reliable buffer between change detection and event publishing |
| **CREATED event** | Event emitted when a record is inserted for the first time; payload contains the full record snapshot |
| **UPDATED event** | Event emitted when an existing record's non-audit fields change; payload contains only the changed fields as `{"field": {"old": X, "new": Y}}` diffs |
| **DELETED event** | Event emitted when a record's status transitions to `DELETED`; payload is empty — the published message carries only entity key, `eventId`, and `send_date` |
| **Entity key** | Composite business key that uniquely identifies a record (e.g., `retail_chain_id + store_id` for stores) |
| **esl-common** | Shared Go library providing CDC types and entity definitions used by multiple components |
