# Architecture

## The request lifecycle

```
Client app
  │  Authorization: Bearer <Entra token, role Gateway.Access>
  │  POST /ai/deployments/gpt-4.1-mini/chat/completions
  ▼
APIM  ai-gateway API  ── INBOUND ─────────────────────────────────────────────
  1. validate-jwt         reject 401 if token missing/invalid/wrong role
  2. extract claims       appid, oid, tid, roles  → context.Variables
  3. build promptText     concat messages[].content (cap 8000 chars)
  4. Content Safety       POST cs-finops-28016 /text:analyze  (managed identity)
                          any category severity >= 4  → return 403, STOP
  5. set-backend-service  aoai-pool
  6. rewrite-uri          /openai/deployments/{deployment}/chat/completions
  7. auth managed-id      token for https://cognitiveservices.azure.com
  ── BACKEND ──────────────────────────────────────────────────────────────────
  8. retry (2x, on 429/5xx)  forward-request → a *different* healthy pool member
  ── OUTBOUND ─────────────────────────────────────────────────────────────────
  9. parse response usage    prompt/completion/total/cached tokens, model
 10. build 1 JSON record     + attribution (cc/bu from roles), latency, status
 11. send-request → DCE      Data Collection Endpoint → DCR → ApimAiGateway_CL
  ▼
Azure OpenAI  (aoai-a | aoai-b | aoai-c)
```

## Why a pool of 3 AOAI accounts?

Each Azure OpenAI account has a **TPM (tokens-per-minute) quota**. One account = one ceiling
and one failure domain. `aoai-pool` combines three:

| Member | Endpoint | Weight | Priority | Note |
|---|---|---|---|---|
| `aoai-a` | aoai-finops-28016 | 100 | 1 | primary (100K TPM) |
| `aoai-b` | aoai-finops-b-28016 | 25 | 2 | overflow (50K TPM) |
| `aoai-c` | aoai-finops-c-28016 | 75 | 2 | overflow (150K TPM) |

Priority 1 is used first; when it throttles/trips, traffic spills to the priority-2 members
split 25/75 by weight. Each member has a **circuit breaker**: 3× (429 or 5xx) within 1 minute
trips it for 1 minute, honoring `Retry-After`. The backend-stage `retry` re-forwards a failed
call immediately to another member, so a single client call can transparently survive a
throttled backend.

## The FinOps cost-attribution model

Four tables, joined at query time:

```
ApimAiGateway_CL         (fact:   one row per call — tokens, latency, status, appid, claims)
      │  lookup on Appid == ClientId
      ▼
ApimClientOwnership_CL   (dim:    appid → Team / CostCenter / BusinessUnit)   [fallback]
      │
      │  lookup on ModelName
      ▼
ApimModelRate_CL         (dim:    model → InputPer1k / OutputPer1k / CachedInputPer1k)
      │
      ▼
   EstCost = (Prompt-Cached)/1k * InputPer1k + Completion/1k * OutputPer1k
      │
      │  join on Team
      ▼
ApimTeamBudget_CL        (dim:    team → MonthlyBudget)
      ▼
   BurnPct = 100 * MtdCost / MonthlyBudget  → OK / WARN_80PCT / OVER_BUDGET
```

### Two-tier attribution (why cost is never lost)
1. **Tier B — JWT claim** (preferred): if the caller's token carries `roles` like
   `cc:CC-2000` / `bu:Discovery`, those are used directly (`AttributionSource = B:jwt-claim`).
2. **Tier A — ownership lookup** (fallback): otherwise the `appid` is matched against
   `ApimClientOwnership_CL` (`AttributionSource = A:lookup`).

An unmatched app still lands as `Team = UNATTRIBUTED` rather than disappearing — so the
"unattributed spend" is itself visible and chase-able.

## Why emit telemetry from the policy (not Diagnostic Settings)?

APIM's built-in diagnostics log requests, but **not the model's token `usage` block** and
**not your custom attribution claims**. Emitting a purpose-built record from the `outbound`
policy lets us capture exactly the FinOps fields we need (tokens, cached tokens, cost tags,
resolved backend host) in a **flat, queryable custom table** with a stable schema (the DCR
stream declaration), instead of digging them out of generic gateway logs.

## Governance vs. the Copilot proxy (sibling repo)

| | This repo (AI Gateway) | `ghc-apim-governance` |
|---|---|---|
| Proxy type | **Reverse** (apps point at APIM) | **Forward** (mitmproxy intercepts Copilot) |
| Supported? | ✅ Yes — standard APIM pattern | ⚠️ No — TLS-interception hack |
| Who calls it | Your own apps (with Entra tokens) | GitHub Copilot CLI (unaware) |
| Adds | Auth + Content Safety + FinOps metering | DLP + Content Safety verdict only |

They solve different problems: this gateway governs **and costs** first-party AI traffic;
the Copilot proxy retrofits governance onto a tool you don't control.
