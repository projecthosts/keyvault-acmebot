@description('The name of the function app that you wish to create.')
@maxLength(14)
param appNamePrefix string

@description('The location of the function app that you wish to create.')
param location string = resourceGroup().location

@description('Email address for ACME account.')
param mailAddress string

@description('Certification authority ACME Endpoint.')
@allowed([
  'https://acme-v02.api.letsencrypt.org/directory'
  'https://acme.zerossl.com/v2/DV90/'
  'https://dv.acme-v02.api.pki.goog/directory'
  'https://acme.entrust.net/acme2/directory'
  'https://emea.acme.atlas.globalsign.com/directory'
])
param acmeEndpoint string = 'https://acme-v02.api.letsencrypt.org/directory'

@description('If you choose true, create and configure a key vault at the same time.')
@allowed([
  true
  false
])
param createWithKeyVault bool = true

@description('Specifies whether the key vault is a standard vault or a premium vault.')
@allowed([
  'standard'
  'premium'
])
param keyVaultSkuName string = 'standard'

@description('Enter the base URL of an existing Key Vault. (ex. https://example.vault.azure.net)')
param keyVaultBaseUrl string = ''

@description('If true, enable DR vault replication for certificates.')
param enableDrReplication bool = false

@description('If true, create a new DR Key Vault. If false, use an existing one specified by drVaultBaseUrl.')
param createWithDrVault bool = false

@description('The Azure region for the new DR Key Vault. Should differ from the primary vault region for disaster recovery.')
param drVaultLocation string = ''

@description('Enter the base URL of an existing DR Key Vault. Required when createWithDrVault is false. (ex. https://example.vault.azure.net)')
param drVaultBaseUrl string = ''

@description('The resource group of the existing DR Key Vault. Required when createWithDrVault is false.')
param drVaultResourceGroup string = ''

@description('Specifies additional name/value pairs to be appended to the function app appsettings.')
param additionalAppSettings array = []

var functionAppName = 'func-${appNamePrefix}-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'
var appServicePlanName = 'plan-${appNamePrefix}-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'
var appInsightsName = 'appi-${appNamePrefix}-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'
var workspaceName = 'log-${appNamePrefix}-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'
var storageAccountName = 'st${uniqueString(resourceGroup().id, deployment().name)}func'
var keyVaultName = 'kv-${appNamePrefix}-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'
var drKeyVaultName = 'kv-${appNamePrefix}-d-${substring(uniqueString(resourceGroup().id, deployment().name), 0, 4)}'

var certOfficerRoleId = resourceId('Microsoft.Authorization/roleDefinitions/', 'a4417e6f-fecd-4de8-b567-7b0420556985')
var secretsUserRoleId = resourceId('Microsoft.Authorization/roleDefinitions/', '4633458b-17de-408a-b874-0445c86b69e0')

// Resolved DR vault URI: auto-generated when creating new, or provided when using existing
var drVaultActualBaseUrl = enableDrReplication
  ? (createWithDrVault
    ? 'https://${drKeyVaultName}${environment().suffixes.keyvaultDns}'
    : drVaultBaseUrl)
  : ''

// Extract vault name from URI for existing vault role assignment (e.g. https://myvault.vault.azure.net -> myvault)
var drVaultNameFromUrl = !empty(drVaultBaseUrl) ? replace(split(drVaultBaseUrl, '.')[0], 'https://', '') : 'placeholder'
var drVaultRgResolved = !empty(drVaultResourceGroup) ? drVaultResourceGroup : resourceGroup().name

var drVaultAppSettings = enableDrReplication ? [
  {
    name: 'Acmebot:DrVaultBaseUrl'
    value: drVaultActualBaseUrl
  }
] : []

var acmebotAppSettings = [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
  {
    name: 'AzureWebJobsStorage'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
  {
    name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
  {
    name: 'WEBSITE_CONTENTSHARE'
    value: toLower(functionAppName)
  }
  {
    name: 'WEBSITE_RUN_FROM_PACKAGE'
    value: 'https://42000acmebot.blob.core.usgovcloudapi.net/releases/keyvault-acmebot.zip'
  }
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'FUNCTIONS_INPROC_NET8_ENABLED'
    value: '1'
  }
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'dotnet-isolated'
  }
  {
    name: 'Acmebot:Contacts'
    value: mailAddress
  }
  {
    name: 'Acmebot:Endpoint'
    value: acmeEndpoint
  }
  {
    name: 'Acmebot:VaultBaseUrl'
    value: (createWithKeyVault ? 'https://${keyVaultName}${environment().suffixes.keyvaultDns}' : keyVaultBaseUrl)
  }
  {
    name: 'Acmebot:Environment'
    value: environment().name
  }
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: {
    'hidden-link:${resourceGroup().id}/providers/Microsoft.Web/sites/${functionAppName}': 'Resource'
  }
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    clientAffinityEnabled: false
    httpsOnly: true
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: concat(acmebotAppSettings, drVaultAppSettings, additionalAppSettings)
      netFrameworkVersion: 'v8.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      cors: {
        allowedOrigins: ['https://portal.azure.com']
        supportCredentials: false
      }
    }
  }
}

// Primary Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (createWithKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: keyVaultSkuName
    }
    enableRbacAuthorization: true
  }
}

// Certificates Officer on primary vault (always required)
resource keyVault_certOfficer_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createWithKeyVault) {
  scope: keyVault
  name: guid(keyVault.id, functionAppName, certOfficerRoleId)
  properties: {
    roleDefinitionId: certOfficerRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Secrets User on primary vault (required for DR export of PFX)
resource keyVault_secretsUser_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createWithKeyVault && enableDrReplication) {
  scope: keyVault
  name: guid(keyVault.id, functionAppName, secretsUserRoleId)
  properties: {
    roleDefinitionId: secretsUserRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// DR Key Vault (new) — created in a separate region for disaster recovery
resource drKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (enableDrReplication && createWithDrVault) {
  name: drKeyVaultName
  location: drVaultLocation
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: keyVaultSkuName
    }
    enableRbacAuthorization: true
  }
}

// Certificates Officer on new DR vault
resource drKeyVault_certOfficer_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDrReplication && createWithDrVault) {
  scope: drKeyVault
  name: guid(drKeyVault.id, functionAppName, certOfficerRoleId)
  properties: {
    roleDefinitionId: certOfficerRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Certificates Officer on existing DR vault (deployed into the DR vault's resource group via module)
module existingDrVault_certOfficer 'modules/keyvaultRoleAssignment.bicep' = if (enableDrReplication && !createWithDrVault) {
  name: 'existingDrVault-certOfficer-roleAssignment'
  scope: resourceGroup(drVaultRgResolved)
  params: {
    vaultName: drVaultNameFromUrl
    principalId: functionApp.identity.principalId
    roleDefinitionId: certOfficerRoleId
  }
}

output functionAppName string = functionApp.name
output principalId string = functionApp.identity.principalId
output tenantId string = functionApp.identity.tenantId
output keyVaultName string = createWithKeyVault ? keyVault.name : ''
output drKeyVaultName string = (enableDrReplication && createWithDrVault) ? drKeyVault.name : ''
