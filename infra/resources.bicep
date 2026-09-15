// Resource-group scoped module: Log Analytics + DCE/DCR, 3x Azure OpenAI accounts,
// Azure AI Content Safety, APIM (Standard v2) with the load-balanced backend pool,
// circuit breakers, JWT auth, Content Safety screening and FinOps telemetry — adapted
// from the reference deployment documented in this repo (apim/, observability/).
param location string
param aadTenantId string
param aadAudienceAppId string
param modelName string
param modelVersion string
param capacityA int
param capacityB int
param capacityC int
param publisherEmail string
param publisherName string

var suffix = uniqueString(resourceGroup().id)
var lawName = 'law-apim-finops-${suffix}'
var dceName = 'dce-apim-finops-${suffix}'
var dcrName = 'dcr-apim-finops-${suffix}'
var apimName = 'apim-finops-${suffix}'
var csName = 'cs-finops-${suffix}'
var aoaiAName = 'aoai-finops-a-${suffix}'
var aoaiBName = 'aoai-finops-b-${suffix}'
var aoaiCName = 'aoai-finops-c-${suffix}'

// ---------------------------------------------------------------------------
// Log Analytics workspace + custom (FinOps) tables
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

var dcrStreams = loadJsonContent('../observability/dcr-streams.json')

resource tableAiGateway 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ApimAiGateway_CL'
  properties: {
    schema: {
      name: 'ApimAiGateway_CL'
      columns: dcrStreams['Custom-ApimAiGateway'].columns
    }
  }
}

resource tableClientOwnership 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ApimClientOwnership_CL'
  properties: {
    schema: {
      name: 'ApimClientOwnership_CL'
      columns: dcrStreams['Custom-ApimClientOwnership'].columns
    }
  }
}

resource tableModelRate 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ApimModelRate_CL'
  properties: {
    schema: {
      name: 'ApimModelRate_CL'
      columns: dcrStreams['Custom-ApimModelRate'].columns
    }
  }
}

resource tableTeamBudget 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'ApimTeamBudget_CL'
  properties: {
    schema: {
      name: 'ApimTeamBudget_CL'
      columns: dcrStreams['Custom-ApimTeamBudget'].columns
    }
  }
}

// ---------------------------------------------------------------------------
// Data Collection Endpoint + Rule (all 4 streams so seed data can be ingested too)
// ---------------------------------------------------------------------------
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: dcrStreams
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'lawDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-ApimAiGateway'
        ]
        destinations: [
          'lawDestination'
        ]
        outputStream: 'Custom-ApimAiGateway_CL'
        transformKql: 'source'
      }
      {
        streams: [
          'Custom-ApimClientOwnership'
        ]
        destinations: [
          'lawDestination'
        ]
        outputStream: 'Custom-ApimClientOwnership_CL'
        transformKql: 'source'
      }
      {
        streams: [
          'Custom-ApimModelRate'
        ]
        destinations: [
          'lawDestination'
        ]
        outputStream: 'Custom-ApimModelRate_CL'
        transformKql: 'source'
      }
      {
        streams: [
          'Custom-ApimTeamBudget'
        ]
        destinations: [
          'lawDestination'
        ]
        outputStream: 'Custom-ApimTeamBudget_CL'
        transformKql: 'source'
      }
    ]
  }
  dependsOn: [
    tableAiGateway
    tableClientOwnership
    tableModelRate
    tableTeamBudget
  ]
}

// ---------------------------------------------------------------------------
// 3x Azure OpenAI accounts (Standard/regional SKU, gpt-4.1-mini deployment each)
// ---------------------------------------------------------------------------
resource aoaiA 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aoaiAName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: aoaiAName
    publicNetworkAccess: 'Enabled'
  }
}

resource aoaiADeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiA
  name: modelName
  sku: {
    name: 'Standard'
    capacity: capacityA
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

resource aoaiB 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aoaiBName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: aoaiBName
    publicNetworkAccess: 'Enabled'
  }
}

resource aoaiBDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiB
  name: modelName
  sku: {
    name: 'Standard'
    capacity: capacityB
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

resource aoaiC 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aoaiCName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: aoaiCName
    publicNetworkAccess: 'Enabled'
  }
}

resource aoaiCDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiC
  name: modelName
  sku: {
    name: 'Standard'
    capacity: capacityC
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// ---------------------------------------------------------------------------
// Azure AI Content Safety
// ---------------------------------------------------------------------------
resource contentSafety 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: csName
  location: location
  kind: 'ContentSafety'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: csName
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// APIM (Standard v2 — supports backend pools + circuit breakers)
// ---------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource backendA 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aoai-a'
  properties: {
    title: 'AOAI A (${capacityA}K TPM)'
    url: 'https://${aoaiAName}.openai.azure.com'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        {
          name: 'openai-throttle'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 429, max: 429 }
              { min: 500, max: 599 }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendB 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aoai-b'
  properties: {
    title: 'AOAI B (${capacityB}K TPM)'
    url: 'https://${aoaiBName}.openai.azure.com'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        {
          name: 'openai-throttle'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 429, max: 429 }
              { min: 500, max: 599 }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendC 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aoai-c'
  properties: {
    title: 'AOAI C (${capacityC}K TPM)'
    url: 'https://${aoaiCName}.openai.azure.com'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        {
          name: 'openai-throttle'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              { min: 429, max: 429 }
              { min: 500, max: 599 }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendPool 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aoai-pool'
  properties: {
    title: 'AOAI gpt-4.1-mini load-balanced pool'
    type: 'Pool'
    pool: {
      services: [
        { id: backendA.id, weight: 100, priority: 1 }
        { id: backendB.id, weight: 25, priority: 2 }
        { id: backendC.id, weight: 75, priority: 2 }
      ]
    }
  }
}

resource backendContentSafety 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'content-safety-backend'
  properties: {
    title: 'Azure AI Content Safety'
    url: contentSafety.properties.endpoint
    protocol: 'http'
  }
}

// ---------------------------------------------------------------------------
// API + policy (adapted from apim/ai-gateway-policy.xml — demo-specific values
// swapped for this deployment's tenant/audience/endpoints/DCR).
// ---------------------------------------------------------------------------
resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'ai-gateway'
  properties: {
    displayName: 'AI Gateway'
    path: 'ai'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment}/chat/completions'
    templateParameters: [
      {
        name: 'deployment'
        type: 'string'
        required: true
      }
    ]
  }
}

var rawPolicy = loadTextContent('../apim/ai-gateway-policy.xml')
var policyStep1 = replace(rawPolicy, 'https://login.microsoftonline.com/f6d12728-e960-45d2-bf98-1421e9bc8453/.well-known/openid-configuration', 'https://login.microsoftonline.com/${aadTenantId}/.well-known/openid-configuration')
var policyStep2 = replace(policyStep1, 'api://bac4c929-2fd5-40ea-8e23-efafa42b2637', 'api://${aadAudienceAppId}')
var policyStep3 = replace(policyStep2, 'https://sts.windows.net/f6d12728-e960-45d2-bf98-1421e9bc8453/', 'https://sts.windows.net/${aadTenantId}/')
var policyStep4 = replace(policyStep3, 'https://cs-finops-28016.cognitiveservices.azure.com', contentSafety.properties.endpoint)
var policyStep5 = replace(policyStep4, 'https://dce-apim-finops-ig7q.eastus2-1.ingest.monitor.azure.com/dataCollectionRules/dcr-b501ac3cf7f54539935329e69351dcb1/streams/Custom-ApimAiGateway?api-version=2023-01-01', '${dce.properties.logsIngestion.endpoint}/dataCollectionRules/${dcr.properties.immutableId}/streams/Custom-ApimAiGateway?api-version=2023-01-01')
var finalPolicy = replace(policyStep5, '"DeploymentRegion", "eastus2"', '"DeploymentRegion", "${location}"')

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: finalPolicy
  }
  dependsOn: [
    operation
    backendPool
    backendA
    backendB
    backendC
    backendContentSafety
  ]
}

// ---------------------------------------------------------------------------
// Role assignments for APIM's system-assigned managed identity
// ---------------------------------------------------------------------------
var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource roleAoaiA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiA.id, apim.id, cognitiveServicesOpenAiUserRoleId)
  scope: aoaiA
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleAoaiB 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiB.id, apim.id, cognitiveServicesOpenAiUserRoleId)
  scope: aoaiB
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleAoaiC 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiC.id, apim.id, cognitiveServicesOpenAiUserRoleId)
  scope: aoaiC
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleContentSafety 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(contentSafety.id, apim.id, cognitiveServicesUserRoleId)
  scope: contentSafety
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, apim.id, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// FinOps workbook (no hardcoded IDs in the source JSON — only sourceId needed)
// ---------------------------------------------------------------------------
resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: guid(law.id, 'ai-gateway-finops-workbook')
  location: location
  kind: 'shared'
  properties: {
    displayName: 'APIM AI Gateway — FinOps'
    serializedData: string(loadJsonContent('../observability/workbook.json'))
    category: 'workbook'
    sourceId: law.id
    version: '1.0'
  }
}

output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output logAnalyticsWorkspaceName string = law.name
output dceName string = dce.name
output dcrName string = dcr.name
output dcrImmutableId string = dcr.properties.immutableId
output contentSafetyEndpoint string = contentSafety.properties.endpoint
output aoaiAName string = aoaiA.name
output aoaiBName string = aoaiB.name
output aoaiCName string = aoaiC.name
