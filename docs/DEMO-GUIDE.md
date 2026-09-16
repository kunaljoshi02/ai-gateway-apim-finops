# Customer demo walkthrough

A 15–20 minute script for demoing the **APIM AI Gateway** — governance
(Entra auth + Content Safety) and FinOps cost attribution — against a live
deployment. Pairs with `infra/DEPLOY.md` (how to stand it up) and
`docs/ARCHITECTURE.md` (how it works under the hood).

## Before the call

- Deploy your own instance per `infra/DEPLOY.md`, or reuse an existing one.
- Have these on hand (fill in from your deployment's outputs):

  | Value | Example (this deployment) |
  |---|---|
  | Gateway URL | `https://apim-finops-h3mamawlufjc6.azure-api.net` |
  | Resource group | `rg-ai-gateway-finops` |
  | Entra tenant ID | your tenant GUID |
  | Test **client** app id + secret | from the app registration you created |
  | Resource app id (audience) | `api://<resourceApp-appId>` |
  | Log Analytics workspace | `law-apim-finops-<suffix>` |
  | Workbook name | "APIM AI Gateway — FinOps" (in the resource group) |

- Open two windows ahead of time:
  1. A terminal (PowerShell) for the live API calls.
  2. The Azure Portal, resource group → the **Workbook**.
- Pre-warm the token cache once so the first live call isn't slow (run the
  "get a token" snippet below once before the call).

## The story (30 seconds, say this first)

> "Every team wants to call Azure OpenAI, but IT needs three things before
> that's safe: **only approved apps can call it** (identity), **no unsafe
> content gets to the model** (safety), and **finance can see who's spending
> what** (cost attribution) — without every app having to send cost metadata
> itself. This is one APIM gateway in front of Azure OpenAI that does all
> three, and it's ~700 lines of policy + Bicep, not a custom platform."

---

## 1. Governance: no token, no access

Show that the gateway itself enforces identity before anything reaches the
model.

```powershell
Invoke-WebRequest -Uri "<gateway-url>/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Method Post -Body '{"messages":[{"role":"user","content":"hi"}]}' `
  -ContentType "application/json" -SkipHttpErrorCheck
```

**Expect:** `401 { "statusCode": 401, "message": "Invalid or missing Entra token" }`

Talking point: *"This isn't an API key check — it's full Entra JWT
validation against our tenant's `openid-configuration`, requiring a specific
app role (`Gateway.Access`). No token, no role, no call."*

## 2. Governance: a valid app can call it

Get a token for the pre-registered **test client** app (client-credentials
flow — this simulates "an approved internal app calling the gateway"):

```powershell
$tenantId    = "<tenant-guid>"
$clientId    = "<test-client-appId>"
$clientSecret= "<test-client-secret>"
$resourceApp = "<resource-app-appId>"

$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
  client_id = $clientId; client_secret = $clientSecret
  scope = "api://$resourceApp/.default"; grant_type = "client_credentials"
}).access_token

Invoke-RestMethod -Method Post -Uri "<gateway-url>/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"Say hello in exactly 3 words."}],"max_tokens":20}'
```

**Expect:** `200` with a normal chat completion response, `finish_reason: "stop"`.

Talking point: *"That request just passed through JWT validation, a Content
Safety screen, and load-balanced routing to one of three Azure OpenAI
accounts — all inside APIM, invisible to the calling app."*

## 3. Governance: Content Safety blocks unsafe prompts

Send a prompt designed to trip a safety category (use a clearly-flagged but
non-graphic test phrase, e.g. one of Azure AI Content Safety's own [sample
test strings](https://learn.microsoft.com/azure/ai-services/content-safety/overview)):

```powershell
Invoke-WebRequest -Uri "<gateway-url>/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"<your test phrase that trips a safety category>"}]}' `
  -SkipHttpErrorCheck
```

**Expect:** `403` with a body like:
```json
{ "error": "content_safety_block", "message": "Prompt blocked by Azure AI Content Safety.", "flaggedCategory": "Hate" }
```

Talking point: *"The model never even saw this prompt — Content Safety
screened it in the gateway's inbound pipeline before `set-backend-service`
routed anywhere."*

## 4. Resilience: load balancing & circuit breakers (talk, don't force it live)

Open the Portal → APIM → **Backends** → `aoai-pool`. Point out:
- 3 members (`aoai-a` 100K TPM weight 100, `aoai-b` 50K TPM weight 25 @
  priority 2, `aoai-c` 150K TPM weight 75 @ priority 2) — traffic favors
  `aoai-a` first, splits proportionally across b/c as a secondary tier.
- Each member has a **circuit breaker**: 3× `429`/`5xx` within 1 minute trips
  it for 1 minute, honoring `Retry-After`.
- The policy's in-request `retry` (2 attempts, first one immediate) means a
  single throttled call can succeed on a *different* pool member before the
  breaker even trips — callers rarely see the throttling at all.

Talking point: *"This is why three modest-capacity accounts beat one big
one for burst traffic — and it's all config, no custom retry code in any
calling app."*

## 5. FinOps: the workbook (the payoff)

Portal → resource group → **Workbooks** → "APIM AI Gateway — FinOps".

Walk the tiles top to bottom (they map 1:1 to `observability/kql/*.kql`):

| Tile | KQL file | What to say |
|---|---|---|
| Fleet KPIs | `01-fleet-kpis.kql` | "Call volume, error rate, total tokens — at a glance." |
| **Estimated cost by team (USD)** | `02-estimated-cost-by-team-usd.kql` | "This is the moment — no app sent us a cost center, we derived it from the JWT + an ownership lookup and priced it from a rate card." |
| Token usage by model | `03-token-usage-by-model.kql` | "Which models are actually being used." |
| Cost attribution by team/cost center | `04-cost-attribution-by-team-cost-center.kql` | "Same data, sliced for a finance/chargeback view." |
| **Budget burn (MTD)** | `05-budget-burn-month-to-date.kql` | "Each team has a monthly budget row; anyone over 80% goes amber, over 100% goes red — this is the FinOps alerting hook." |
| Token trend by team | `06-token-trend-by-team.kql` | "Trend over time, to catch a runaway integration early." |
| p95 latency by model | `07-latency-p95-by-model-ms.kql` | "Performance, not just cost." |
| Errors by model/reason | `08-errors-by-model-reason.kql` | "Where throttling or failures are concentrated." |
| Top apps by token usage | `09-top-apps-by-token-usage.kql` | "Who's actually driving the spend." |

Then run the live call from step 2 again, wait ~30–60 seconds, and refresh
the workbook — the new row shows up in real time, attributed to the test
client's team.

Talking point: *"Nothing in this workbook required the calling application
to change — the attribution model works even for apps that will never add
cost-center headers themselves."*

## 6. Wrap-up talking points

- **One gateway, three concerns**: identity, safety, cost — no separate
  proxy or SDK wrapper needed in each calling app.
- **All config, no custom code**: the entire behavior is an APIM policy +
  backend/pool JSON + a Data Collection Rule; `infra/` shows it's fully
  reproducible as Bicep.
- **Extendable**: swap in more Azure OpenAI accounts/regions by adding pool
  members; add more cost dimensions by extending the ownership lookup;
  reuse the same pattern for Foundry models or other providers behind APIM.

## Common Q&A

- **"What if the app doesn't have an Entra token?"** → It's rejected at
  `validate-jwt`, before Content Safety or the model are ever touched (see
  step 1).
- **"What's the added latency?"** → Content Safety + telemetry emission adds
  low double-digit ms typically; the workbook's p95 tile shows real numbers
  from your traffic.
- **"Does this work with streaming responses?"** → The reference policy
  meters non-streaming `usage` blocks; streaming token counts would need an
  SSE-aware outbound step (a known extension point, not implemented here).
- **"Can we self-tag cost center instead of the lookup table?"** → Yes — see
  step 1's talking point: a `cc:`/`bu:` claim in the token's `roles` short-
  circuits the ownership lookup (`AttributionSource: B:jwt-claim` in the KQL).

## Cleanup

If this was a throwaway demo environment:

```powershell
az group delete --name <resource-group> --yes --no-wait
```

Also remove the two Entra app registrations (`ai-gateway-finops-resource`,
`ai-gateway-finops-client`) if they aren't reused for the next demo.
