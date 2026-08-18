# Deploy scripts

These are reference helpers. Set the env vars at the top of each to match your environment
before running. They are idempotent-ish but review before running against a real APIM.

| Script | Purpose |
|---|---|
| `import-policy.sh` | Imports `apim/ai-gateway-policy.xml` onto the `ai-gateway` API. |

> Reference data (`seed/*.json`) is uploaded into the `_CL` tables via the DCR ingestion
> endpoint. The `ApimClientOwnership_CL`, `ApimModelRate_CL`, and `ApimTeamBudget_CL` streams
> accept the same POST shape as the usage stream (see the outbound `send-request` in the
> policy) — post each JSON array to its stream on the DCE.

## Common variables

```bash
export SUBSCRIPTION_ID=68837237-5a48-41a9-bed4-947f5c277684
export RG=rg-apim-finops-demo
export APIM=apim-finops-28016
export API_ID=ai-gateway
```

## Values to replace in the policy before importing

Search `apim/ai-gateway-policy.xml` for these demo-specific values and swap for yours:

| Placeholder in file | Meaning |
|---|---|
| `cs-finops-28016.cognitiveservices.azure.com` | Your Content Safety endpoint |
| `login.microsoftonline.com/f6d12728-...` | Your Entra tenant id |
| `api://bac4c929-...` | Your API's app-registration audience |
| `sts.windows.net/f6d12728-.../` | Your token issuer |
| `dce-apim-finops-ig7q...ingest.monitor.azure.com` | Your Data Collection Endpoint |
| `dcr-b501ac3cf7...` | Your DCR immutable id |
