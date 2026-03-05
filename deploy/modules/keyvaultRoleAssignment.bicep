param vaultName string
param principalId string
param roleDefinitionId string

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: vaultName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
