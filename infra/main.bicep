// Deploys a brand-new instance of the APIM AI Gateway (governance + FinOps) into a new
// resource group. See infra/DEPLOY.md for usage.
targetScope = 'subscription'

@description('Name of the new resource group to create.')
param resourceGroupName string = 'rg-ai-gateway-finops'

@description('Azure region for all resources.')
param location string = 'swedencentral'

@description('Entra tenant id used for validate-jwt (openid-config + issuer).')
param aadTenantId string

@description('Application (client) id of the Entra app registration that represents this API (used to build the api://<appId> audience).')
param aadAudienceAppId string

@description('Deployment name / model name for the AOAI chat completions deployment.')
param modelName string = 'gpt-4.1-mini'

@description('Model version to deploy.')
param modelVersion string = '2025-04-14'

@description('TPM capacity (in units of 1,000 tokens/min) for the primary AOAI account (aoai-a).')
param capacityA int = 100

@description('TPM capacity (in units of 1,000 tokens/min) for the overflow AOAI account (aoai-b).')
param capacityB int = 50

@description('TPM capacity (in units of 1,000 tokens/min) for the overflow AOAI account (aoai-c).')
param capacityC int = 150

@description('Publisher email required by APIM.')
param publisherEmail string

@description('Publisher name required by APIM.')
param publisherName string = 'AI Gateway FinOps'

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
}

module resources 'resources.bicep' = {
  name: 'ai-gateway-finops-resources'
  scope: rg
  params: {
    location: location
    aadTenantId: aadTenantId
    aadAudienceAppId: aadAudienceAppId
    modelName: modelName
    modelVersion: modelVersion
    capacityA: capacityA
    capacityB: capacityB
    capacityC: capacityC
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

output resourceGroupName string = rg.name
output apimGatewayUrl string = resources.outputs.apimGatewayUrl
output apimName string = resources.outputs.apimName
output logAnalyticsWorkspaceName string = resources.outputs.logAnalyticsWorkspaceName
