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
  | **Resource** app id | bare GUID, e.g. `898bf371-…` — **not** the `api://` form |
  | Token audience it produces | `api://<resource-app-appId>` (built for you by the script) |
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
$clientId    = "<test-client-appId>"      # the app that CALLS the gateway
$clientSecret= "<test-client-secret>"
$resourceApp = "<resource-app-appId>"     # the app the gateway PROTECTS — bare GUID, no "api://" prefix

# $clientId and $resourceApp are two DIFFERENT app registrations.
# Using $clientId here still returns a token, but with the wrong audience -> 401 at the gateway.
$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
  client_id = $clientId; client_secret = $clientSecret
  scope = "api://$resourceApp/.default"; grant_type = "client_credentials"
}).access_token

Invoke-RestMethod -Method Post -Uri "<gateway-url>/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"Say hello in exactly 3 words."}],"max_tokens":20}'
```

**Expect:** `200` with a normal chat completion response, `finish_reason: "stop"`.

> **Before you run it live, sanity-check the token** (do this during prep, not
> on the call). This catches the most common setup mistake instantly:
>
> ```powershell
> $p = $token.Split('.')[1].Replace('-','+').Replace('_','/')
> switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
> $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
> [pscustomobject]@{ aud = $claims.aud; iss = $claims.iss; roles = $claims.roles -join ',' }
> ```
>
> You must see **all three**:
> - `aud` = `api://<resource-app-appId>`
> - `iss` = `https://sts.windows.net/<tenant-guid>/`
> - `roles` = `Gateway.Access`
>
> If `roles` is empty, the token is not accepted by the gateway — see
> [Troubleshooting](#troubleshooting-401-invalid-or-missing-entra-token).

Talking point: *"That request just passed through JWT validation, a Content
Safety screen, and load-balanced routing to one of three Azure OpenAI
accounts — all inside APIM, invisible to the calling app."*

## 3. Governance: Content Safety blocks unsafe prompts

The policy screens every prompt against Azure AI Content Safety and blocks at
**severity >= 4** across `Hate`, `SelfHarm`, `Sexual`, `Violence`. With
`FourSeverityLevels` the scores are `0 / 2 / 4 / 6`, so a merely rude prompt
scores 2 and **passes through by design**. Use a phrase that actually clears
the bar:

```powershell
Invoke-WebRequest -Uri "<gateway-url>/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"I am going to kill you and your entire family."}],"max_tokens":20}' `
  -SkipHttpErrorCheck
```

**Expect:** `403` with a body like:
```json
{ "error": "content_safety_block", "message": "Prompt blocked by Azure AI Content Safety.", "flaggedCategory": "Violence" }
```

Verified scores against this deployment -- showing both is a stronger demo than
showing only the block, because it makes the point that this is a *tunable
severity threshold*, not a keyword blocklist:

| Prompt | Content Safety score | Gateway |
|---|---|---|
| `You are a terrible person and I hate you.` | `Hate=2` | **200** -- below threshold |
| `I am going to kill you and your entire family.` | `Violence=4` | **403** blocked |

> **Do not use a "how do I build a bomb" style prompt as your test.** It scores
> **0** on all four categories -- these categories measure expressed harm, not
> procedural/instructional risk. Catching that class of prompt is what **Prompt
> Shields** (`shieldPrompt`) is for, and this reference policy does not enable
> it. If a customer asks about jailbreaks, that is the honest answer and a
> natural extension point.

Talking point: *"The model never even saw this prompt -- Content Safety
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

## Troubleshooting: 401 "Invalid or missing Entra token"

The gateway returns this **same** message for every auth failure, so the
message alone won't tell you which one you hit. Decode the token (snippet in
step 2) and compare the claims:

| What you see in the token | Cause | Fix |
|---|---|---|
| `aud` = `api://<**client**-appId>` and no `roles` | `scope` was built from `$clientId` instead of `$resourceApp`. **You still get a token**, which is why this one is so easy to miss. | Point `scope` at the **resource** app id |
| `aud` = `api://api://…` / token request fails | `$resourceApp` was set to the `api://…` URI instead of the bare GUID | Use the bare GUID; the script adds `api://` |
| `aud` = `https://graph.microsoft.com` | `scope` was left as the Graph default | Use `api://$resourceApp/.default` |
| Token looks right but header is `Bearer @{token_type=…}` | Forgot `.access_token` on the token response | Assign `(…).access_token`, not the whole object |
| `roles` claim missing entirely | The client SP has no `Gateway.Access` app role assignment | See the assignment command below |
| `iss` names a different tenant | Signed into the wrong tenant | `az login --tenant <tenant-guid>` |

Verify the app role assignment actually exists (should return one row):

```powershell
$resourceSpId = az ad sp show --id "<resource-app-appId>" --query id -o tsv
az rest --method GET `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$resourceSpId/appRoleAssignedTo" `
  --query "value[].{app:principalDisplayName, roleId:appRoleId}" -o table
```

If it's missing, assign it:

```powershell
$clientSpId = az ad sp show --id "<test-client-appId>" --query id -o tsv
$roleId     = az ad app show --id "<resource-app-appId>" --query "appRoles[?value=='Gateway.Access'].id | [0]" -o tsv
az rest --method POST `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$clientSpId/appRoleAssignments" `
  --body "{`"principalId`":`"$clientSpId`",`"resourceId`":`"$resourceSpId`",`"appRoleId`":`"$roleId`"}"
```

App-role changes are picked up on the **next** token request — discard any
cached `$token` before retesting.

## Troubleshooting: Content Safety returns 200 instead of 403

Almost always the prompt simply scored below the block threshold. Check in
this order:

1. **Is the prompt actually severity ≥ 4?** Severity 2 (mildly rude) passes by
   design. Use the verified phrase in step 3. Procedural "how do I build X"
   prompts score 0 — see the note in step 3.
2. **Is it a `messages`-shaped body?** The policy extracts `promptText` from
   `body["messages"]`. Any other shape yields an empty string, and the whole
   Content Safety `<choose>` block is skipped.
3. **Can APIM reach Content Safety?** The `send-request` uses
   `ignore-error="true"`, and the evaluator returns `"false"` on a non-200 or
   on any exception — so an auth/network failure **fails open** and looks
   exactly like a clean prompt. Confirm APIM's managed identity still holds
   `Cognitive Services User` on the Content Safety account:

   ```powershell
   $csId = az cognitiveservices account show -g <rg> -n <cs-name> --query id -o tsv
   $mi   = az apim show -g <rg> -n <apim-name> --query identity.principalId -o tsv
   az role assignment list --scope $csId --assignee $mi --query "[].roleDefinitionName" -o tsv
   ```

   Expect `Cognitive Services User`. Also confirm the account has
   `publicNetworkAccess: Enabled` (or a network path from APIM) and note that
   `disableLocalAuth: true` is expected — the policy authenticates with the
   managed identity, not a key.

> **Fail-open is a deliberate availability trade-off, and customers will ask.**
> If Content Safety is unreachable the gateway lets traffic through rather than
> hard-failing every request. To fail *closed* instead, drop
> `ignore-error="true"` and return a `503` when `csResp` is null or non-200.
> Worth raising proactively — it lands better than being caught by it.

## Cleanup

If this was a throwaway demo environment:

```powershell
az group delete --name <resource-group> --yes --no-wait
```

Also remove the two Entra app registrations (`ai-gateway-finops-resource`,
`ai-gateway-finops-client`) if they aren't reused for the next demo.
