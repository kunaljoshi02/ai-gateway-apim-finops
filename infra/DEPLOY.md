# Deploying a fresh instance

This folder contains Bicep that provisions a brand-new copy of the AI Gateway
(APIM + 3x Azure OpenAI + Content Safety + Log Analytics/DCR + FinOps
workbook) into its own resource group, wiring in the policy/backends/schema
from `apim/` and `observability/` in this repo.

## Prerequisites

1. An Entra ID **resource app registration** representing this API, with:
   - `identifierUris` set to `api://<appId>`
   - An app role (e.g. `Gateway.Access`, `allowedMemberTypes: Application`)
     required by `validate-jwt` in `apim/ai-gateway-policy.xml`.
2. A **client app registration** (service principal) assigned that app role,
   used to obtain client-credentials tokens for calling the gateway.

```powershell
# Resource app
$resourceApp = az ad app create --display-name "ai-gateway-finops-resource" -o json | ConvertFrom-Json
az ad app update --id $resourceApp.appId --identifier-uris "api://$($resourceApp.appId)"
$role = @{ allowedMemberTypes = @("Application"); displayName = "Gateway Access"; id = [guid]::NewGuid(); isEnabled = $true; description = "Allows calling the AI Gateway"; value = "Gateway.Access" }
@($role) | ConvertTo-Json -Depth 5 | Out-File approles.json
az ad app update --id $resourceApp.appId --set appRoles=@approles.json
$resourceSp = az ad sp create --id $resourceApp.appId -o json | ConvertFrom-Json

# Client app + secret
$clientApp = az ad app create --display-name "ai-gateway-finops-client" -o json | ConvertFrom-Json
$clientSp = az ad sp create --id $clientApp.appId -o json | ConvertFrom-Json
$secret = az ad app credential reset --id $clientApp.appId --years 1 -o json | ConvertFrom-Json
$body = @{ principalId = $clientSp.id; resourceId = $resourceSp.id; appRoleId = $role.id } | ConvertTo-Json
$body | Out-File approleassign.json
az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($resourceSp.id)/appRoleAssignedTo" --body "@approleassign.json" --headers "Content-Type=application/json"
```

## Deploy

```powershell
az deployment sub create `
  --name ai-gateway-finops-deploy `
  --location swedencentral `
  --template-file infra/main.bicep `
  --parameters aadTenantId=<tenant-guid> aadAudienceAppId=<resourceApp-appId> publisherEmail=<you@contoso.com>
```

This creates (default names use a `uniqueString()` suffix, all in one new
resource group, default `rg-ai-gateway-finops`):

- Log Analytics workspace + 4 custom tables (`ApimAiGateway_CL`, `ApimClientOwnership_CL`, `ApimModelRate_CL`, `ApimTeamBudget_CL`)
- Data Collection Endpoint + Data Collection Rule (all 4 streams)
- 3x Azure OpenAI accounts (`gpt-4.1-mini`, Standard/regional SKU) at 100K/50K/150K TPM
- Azure AI Content Safety account
- APIM (Standard v2) with a `aoai-pool` backend (weighted/prioritized across the
  3 AOAI backends, each with a circuit breaker) and the adapted policy from
  `apim/ai-gateway-policy.xml` (tenant/audience/Content Safety endpoint/DCR
  ingestion URL are substituted at deploy time via `replace()`)
- Role assignments for APIM's system-assigned identity (Cognitive Services
  OpenAI User, Cognitive Services User, Monitoring Metrics Publisher)
- The FinOps workbook (`observability/workbook.json`) pointed at the new
  workspace

## Seed reference data

After deployment, POST `seed/*.json` (with a `TimeGenerated` field added) to
the DCR's other 3 streams via the Logs Ingestion API, using a principal that
has been granted **Monitoring Metrics Publisher** on the DCR:

```powershell
$token = az account get-access-token --resource "https://monitor.azure.com" --query accessToken -o tsv
$url = "<dce-logsIngestion-endpoint>/dataCollectionRules/<dcr-immutableId>/streams/Custom-ApimClientOwnership?api-version=2023-01-01"
Invoke-WebRequest -Method Post -Uri $url -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body (Get-Content seed/client-ownership.json -Raw)
```

## Test

```powershell
$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token" -Body @{
  client_id = "<clientApp-appId>"; client_secret = "<secret>"; scope = "api://<resourceApp-appId>/.default"; grant_type = "client_credentials"
}).access_token

Invoke-RestMethod -Method Post -Uri "https://<apim-name>.azure-api.net/ai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-08-01-preview" `
  -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" `
  -Body '{"messages":[{"role":"user","content":"hello"}]}'
```

> The AOAI data-plane requires `api-version` on the query string — pass it
> through as you would calling Azure OpenAI directly.
