# Azure deployment — Phase 1 (cloud nightly dream)

Runs the nightly **dream** consolidation in Azure so it happens **even when your
machine is off**, and keeps `memory.db` durable on an Azure Files share. The engine
is unchanged — only *where it runs* moves to the cloud.

## Why

Microsoft Scout runs locally, so **recall** and writing memories back into Scout's
bank still need your machine on *at some point*. What this deployment fixes is the
part that must be reliable regardless of your machine: the **nightly consolidation**
and a **durable central store**.

```
┌ Your Mac (only when on) ┐        ┌ Azure (always on) ───────────────┐
│  Microsoft Scout        │  push  │  Container Apps Job (cron 03:00)  │
│  recall + memory bank   ├───────▶│   = the dream engine             │
│  scout-sync.sh          │◀───────┤  Azure Files: memory.db          │
└─────────────────────────┘  pull  │   inbox/snapshot.json            │
                                    │   outbox/export-harness.json     │
                                    └──────────────────────────────────┘
```

## What gets created

| Resource | Name (default) | Purpose |
| --- | --- | --- |
| Resource group | `rg-scout-graph-memory` | container for everything |
| Storage account + File share | `stscoutmem*` / `memory` | durable `memory.db`, `inbox/`, `outbox/` |
| Container Registry | `acrscoutmem*` | holds the cloud-built image |
| Container Apps environment | `cae-scout-memory` | runtime + linked Azure Files |
| Container Apps **Job** | `job-scout-dream` | scheduled nightly dream (cron, UTC) |

Cost is a few dollars/month: the job runs a couple of minutes a night (scales to
zero), plus a tiny standard file share and a Basic registry.

## Prerequisites

- `az login` (this repo was validated against Azure CLI 2.83).
- **No local Docker** — the image is built in the cloud with ACR Tasks.
- Bash + `python3` (used to patch the job's volume mount).

## Deploy

From the repo root:

```bash
./azure/deploy.sh
```

Override any default via env vars, e.g.:

```bash
LOCATION=westeurope RG=rg-my-memory CRON="0 1 * * *" ./azure/deploy.sh
```

Then trigger a one-off run to verify:

```bash
az containerapp job start -n job-scout-dream -g rg-scout-graph-memory
az containerapp job execution list -n job-scout-dream -g rg-scout-graph-memory -o table
```

## The cron / timezone note

Container Apps Jobs schedule in **UTC**. The default `0 0 * * *` is **03:00 in
Asia/Jerusalem during summer DST (UTC+3)** and 02:00 in winter (UTC+2). Change
`CRON` if you want a fixed local hour year-round.

## Wiring Scout to the cloud store

The cloud job consolidates whatever is in `inbox/snapshot.json` and writes the
curated set to `outbox/export-harness.json`. A lightweight **Scout automation**
(runs when your Mac is on) keeps the two in sync:

1. **Push** — dump `m_list_memories` to a local `snapshot.json`, then
   `SGM_STORAGE=… SGM_SHARE=memory SGM_RG=… ./azure/sync/scout-sync.sh push snapshot.json`.
2. **(optional) Trigger** — `scout-sync.sh run-now` to dream immediately instead of waiting for the cron.
3. **Pull** — `scout-sync.sh pull export.json`, then reconcile into the bank:
   `m_remember` new/changed facts, `m_forget` the stale ones (apply only the diff).

Because the heavy consolidation math runs in Azure nightly, the Mac-side step is a
fast push/pull that can run at any convenient time the machine is on.

## Teardown

```bash
az group delete -n rg-scout-graph-memory --yes --no-wait
```
