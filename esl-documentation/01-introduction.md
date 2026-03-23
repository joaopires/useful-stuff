---
title: "ESL Orchestrator"
subtitle: "Phase 1 — Technical Documentation"
author: "João Pires - Devoteam"
affiliation: "Sonae MC"
lang: "en"
---

```{=typst}
#show link: set text(fill: blue)
```

# Introduction

## Purpose

This document provides the technical documentation for **Phase 1** of the ESL (Electronic Shelf Label) Orchestrator platform at Sonae MC. The platform synchronises ESL data — stores, products, labels and access points — from the Vusion ecosystem into a centralised PostgreSQL database and exposes it through a read-only REST API.

Phase 1 delivers three components:

| Component | Role |
|---|---|
| **Data Pipeline** | Scheduled job that fetches data from Vusion Manager and VLink APIs, transforms it, and writes it to PostgreSQL |
| **Database** | Flyway-managed PostgreSQL schema that stores all ESL entities and synchronisation state |
| **DataFetch API** | REST API that serves the stored data to downstream consumers with pagination and search |

## Scope

This document covers the architecture, design, deployment, and operational aspects of the Phase 1 components. Future phases will introduce additional components and capabilities, which will be documented separately.

## Audience

This document is intended for:

- **Technical stakeholders** who need to understand the system's architecture and design decisions
- **Developers** who will extend or maintain the platform
- **Operations teams** who will deploy, configure, and monitor the system
- **Project managers and product owners** who need visibility into the platform's capabilities

Technical sections include code and configuration examples with explanations. Architecture diagrams provide a visual overview suitable for all readers.

## How to Read This Document

The document is structured in the following order:

1. **System Architecture** — High-level view of all components and how they interact
2. **Database** — Schema design, tables, and migration management
3. **Data Pipeline** — Synchronisation engine, connectors, and configuration
4. **DataFetch API** — REST API, endpoints, search, and security
5. **Deployment & Infrastructure** — Kubernetes, ArgoCD, secrets, and networking
6. **Operations & Maintenance** — Monitoring, common tasks, and troubleshooting

Readers looking for a high-level understanding can focus on the Architecture section. Those responsible for day-to-day operations should pay particular attention to the Deployment and Operations sections.

## Glossary

| Term | Description |
|---|---|
| **ESL** | Electronic Shelf Label — digital price tags used in retail stores |
| **Vusion** | SES-imagotag's ESL platform, consisting of hardware and cloud services |
| **Vusion Manager** | Vusion's store management API — provides store metadata |
| **VLink** | Vusion's in-store API — provides product, label, and access point data |
| **Access Point** | Radio transmitter hardware in a store that communicates with ESL labels |
| **ArgoCD** | GitOps continuous delivery tool for Kubernetes |
| **Flyway** | Database migration tool that versions schema changes as SQL files |
| **Helm** | Kubernetes package manager used to template deployment manifests |
| **CronJob** | Kubernetes resource that runs a job on a recurring schedule |
| **UPSERT** | Database operation that inserts a row or updates it if it already exists |
| **Incremental Sync** | Synchronisation mode that only fetches records modified since the last run |
| **Full Sync** | Synchronisation mode that fetches all records regardless of modification date |
| **External Secrets Operator** | Kubernetes operator that syncs secrets from external vaults |
| **OpenTelemetry** | Observability framework for distributed tracing and metrics |
| **Prometheus** | Monitoring system used for metrics collection and alerting |
