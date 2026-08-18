# Log Analytics table schemas

These four **custom tables** live in workspace `law-apim-finops`. The DCR `dcr-apim-finops` routes each stream to its `_CL` table.

## `ApimAiGateway_CL`

Per-request usage/telemetry emitted by the API `outbound` policy. One row per model call.

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `RequestId` | string |
| `OperationId` | string |
| `ApiName` | string |
| `ApiId` | string |
| `OperationName` | string |
| `ProductName` | string |
| `SubscriptionName` | string |
| `RouteClass` | string |
| `ModelName` | string |
| `ModelVersion` | string |
| `BackendId` | string |
| `DeploymentRegion` | string |
| `StatusCode` | int |
| `IsError` | boolean |
| `ErrorReason` | string |
| `TotalLatencyMs` | real |
| `BackendLatencyMs` | real |
| `PromptTokens` | int |
| `CompletionTokens` | int |
| `TotalTokens` | int |
| `CachedPromptTokens` | int |
| `IsStreaming` | boolean |
| `TokenSource` | string |
| `ClientId` | string |
| `Appid` | string |
| `Oid` | string |
| `UpnOrAppName` | string |
| `TenantIdClaim` | string |
| `BusinessUnitClaim` | string |
| `CostCenterClaim` | string |
| `RequestBytes` | int |
| `ResponseBytes` | int |
| `PolicyVersion` | string |

## `ApimClientOwnership_CL`

Reference/dimension table mapping each client app (Entra appId) to its owning Team, Cost Center, and Business Unit. Used as a fallback when the JWT has no cost tags.

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `ClientId` | string |
| `AppName` | string |
| `Team` | string |
| `CostCenter` | string |
| `BusinessUnit` | string |

## `ApimModelRate_CL`

Reference/dimension table of price-per-1k-tokens for each model. Joined to usage to compute estimated cost.

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `ModelName` | string |
| `ModelVersion` | string |
| `InputPer1k` | real |
| `OutputPer1k` | real |
| `CachedInputPer1k` | real |
| `Currency` | string |
| `EffectiveFrom` | datetime |

## `ApimTeamBudget_CL`

Reference/dimension table of each teams monthly budget. Used for budget-burn %.

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `Team` | string |
| `MonthlyBudget` | real |
| `Currency` | string |
