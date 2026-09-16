# APIM AI Gateway — Governance + FinOps Observability

A working **Azure API Management (APIM) "AI Gateway"** in front of Azure OpenAI that adds
enterprise **governance** (Entra auth + Content Safety) and full **FinOps cost
observability** (per-request token metering → Log Analytics → cost attribution by
team / cost center / business unit, with budget-burn alerts).

This repo captures the exact policies, backend/load-balancing config, telemetry pipeline,
KQL, and dashboard from a live deployment on `apim-finops-28016`.

> Sibling project: [`ghc-apim-governance`](https://github.com/natesanshreyas/ghc-apim-governance)
> gates the **GitHub Copilot CLI** via a forward proxy. **This** repo is the *reverse-proxy*
> AI Gateway for **your own apps** calling Azure OpenAI — the officially supported pattern.

---

## What it does (one screen)

```
                          ┌──────────────────────── APIM AI Gateway ────────────────────────┐
                          │  INBOUND                                                         │
  App (Entra token) ──────┼─► validate-jwt (Entra, role: Gateway.Access)                     │
                          │  ├─ extract claims: appid, oid, tid, roles (cc:*, bu:*)          │
                          │  ├─ Content Safety screen (Hate/SelfHarm/Sexual/Violence ≥4→403) │
                          │  └─ route → aoai-pool  (weighted, priority, circuit breakers)    │
                          │  BACKEND: retry on 429/5xx → next healthy pool member            │
                          │  OUTBOUND                                                        │──► Azure OpenAI
                          │  └─ parse usage → emit 1 telemetry row → Log Analytics (DCR)      │    (3 accounts)
                          └──────────────────────────────────────────────────────────────────┘
                                                        │
                                    ApimAiGateway_CL  (per-request tokens, latency, claims)
                                                        │
                    ┌───────────────────────────────────┴───────────────────────────────────┐
                    │  Workbook "APIM AI Gateway — FinOps"  joins usage × rates × budgets     │
                    │  → cost by team/cost-center, budget burn %, token trend, p95, errors    │
                    └────────────────────────────────────────────────────────────────────────┘
```

Two concerns, one gateway:
- **Governance** — nobody reaches the model without a valid Entra token *and* a clean
  Content Safety check.
- **FinOps** — every call is metered and attributed to a **team / cost center / business
  unit**, priced from a **rate card**, and compared to a **monthly budget** — all without
  the app sending any cost metadata (attribution comes from the JWT + an ownership lookup).

---

## Repo layout

| Path | What's in it |
|---|---|
| `apim/ai-gateway-policy.xml` | The **full API policy** — JWT, claim extraction, Content Safety, pool routing, retry, and the outbound telemetry emitter. |
| `apim/backends.json` | The **load-balanced pool** (`aoai-pool`) + 3 AOAI members with weights/priorities and **circuit-breaker** rules. |
| `observability/dcr-streams.json` | The 4 **DCR stream declarations** (column schemas) sent to Log Analytics. |
| `observability/tables/SCHEMAS.md` | Human-readable schema for each `_CL` table. |
| `observability/kql/*.kql` | The **9 dashboard queries** (cost, budget burn, trend, latency, errors, top apps). |
| `observability/workbook.json` | The **Azure Monitor Workbook** ("APIM AI Gateway — FinOps") serialized definition. |
| `seed/*.json` | Reference data: **model rate card**, **client→owner mapping**, **team budgets**. |
| `docs/ARCHITECTURE.md` | How each piece fits + the cost-attribution model explained. |
| `docs/DEMO-GUIDE.md` | Step-by-step script for walking a customer through a live demo. |
| `scripts/` | Deploy helpers (policy import, backend/pool creation, DCR + seed upload). |
| `infra/` | **Bicep** to stand up a brand-new, self-contained copy of this whole stack (APIM, 3x AOAI, Content Safety, Log Analytics/DCR, workbook) in your own subscription. See `infra/DEPLOY.md`. |

---

## Deploy your own

`infra/` provisions a fresh instance of everything above into a new resource
group — no dependency on the original demo deployment. See `infra/DEPLOY.md`
for the Entra app registration prerequisites and the `az deployment sub create`
command.

---

## The three governance + FinOps mechanics

### 1. Identity & attribution (inbound)
`validate-jwt` requires an Entra token with role `Gateway.Access`. Claims are pulled out:
- `appid` → **which app** made the call (the FinOps join key)
- `roles` may carry `cc:<costcenter>` and `bu:<businessunit>` → **direct cost tags**

If the token has no cost tags, the dashboards fall back to the **ownership lookup**
(`seed/client-ownership.json`) — so cost is attributed **even for apps that don't self-tag**.

### 2. Content Safety (inbound)
The prompt text is concatenated and sent to **Azure AI Content Safety** via managed identity.
Any category (Hate / SelfHarm / Sexual / Violence) at **severity ≥ 4** → immediate **403**,
model never contacted.

### 3. Load balancing + resilience (backend)
`aoai-pool` spreads load across **3 AOAI accounts** by weight/priority. Each member has a
**circuit breaker** (trip on 3× 429/5xx in 1 min, honor `Retry-After`). An in-request
`retry` re-forwards a failed call to a **different healthy member** — callers often succeed
before the breaker even trips.

### 4. Token metering → cost (outbound)
On the way out, the policy parses the model's `usage` block and emits **one JSON row** to a
**Data Collection Rule** → `ApimAiGateway_CL`. The workbook then computes cost:

```
EstCost = (PromptTokens - CachedPromptTokens)/1000 * InputPer1k
        +  CompletionTokens/1000               * OutputPer1k
```

joined to `ApimModelRate_CL`, grouped by team, compared to `ApimTeamBudget_CL` for
**budget-burn %** (`OK` / `WARN_80PCT` / `OVER_BUDGET`).

---

## Live deployment reference

| Resource | Name |
|---|---|
| APIM | `apim-finops-28016` |
| API | `ai-gateway` (path `ai`), op `chat-completions` |
| Backends | `aoai-a` / `aoai-b` / `aoai-c` → pool `aoai-pool` |
| Content Safety | `cs-finops-28016` |
| Log Analytics | `law-apim-finops` |
| DCR | `dcr-apim-finops` (4 streams) |
| Workbook | *APIM AI Gateway — FinOps* |
| Resource group | `rg-apim-finops-demo` |

---

## Quick start

1. **Deploy AOAI + APIM + Content Safety + Log Analytics** (or reuse existing).
2. **Create the pool & backends** — see `apim/backends.json` (weights, priorities, breakers).
3. **Import the policy** — `apim/ai-gateway-policy.xml` onto the `ai-gateway` API.
   Replace the Content Safety endpoint, DCE/DCR ingestion URL, tenant id, and audience with
   your own values (search the file for `28016`, `login.microsoftonline.com`, `ingest.monitor`).
4. **Create the DCR + custom tables** from `observability/dcr-streams.json`.
5. **Seed reference data** — upload `seed/*.json` into the `_CL` reference tables.
6. **Import the workbook** — `observability/workbook.json`, point it at `law-apim-finops`.
7. **Call it** with an Entra token that has `Gateway.Access`:
   ```
   POST https://apim-finops-28016.azure-api.net/ai/deployments/gpt-4.1-mini/chat/completions
   Authorization: Bearer <entra-token>
   { "messages": [ { "role": "user", "content": "hello" } ] }
   ```
   Then open the workbook — your call shows up as cost against its team.

See `docs/ARCHITECTURE.md` for the full walk-through.

---

## Notes / caveats
- Cost is **estimated** from a static rate card (`ApimModelRate_CL`), not billed invoice cost.
- `BackendLatencyMs` is approximate unless the backend returns `x-ms-apim-backend-time`.
- Streaming responses don't return a `usage` block; `TokenSource=none` rows aren't priced.
- Tenant id, audience, endpoints in the policy are from the demo env — swap for yours.
