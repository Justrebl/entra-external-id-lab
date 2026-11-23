targetScope = 'tenant'

extension microsoftGraphV1

@description('Stable deployment prefix. Keep it unchanged across redeployments.')
@minLength(1)
@maxLength(40)
param namePrefix string = 'DEMO'

@description('Optional app suffix. Keep it unchanged across redeployments.')
@maxLength(20)
param appSuffix string = ''

var uniqueNameSuffix = empty(appSuffix) ? '' : '-${toUpper(appSuffix)}'
var displayNameSuffix = empty(appSuffix) ? '' : '_${toUpper(appSuffix)}'
var apiUniqueName = '${namePrefix}-API${uniqueNameSuffix}'
var apiIdentifierUri = 'api://${tenant().tenantId}/${apiUniqueName}'
var crmReadScopeName = 'CRM.Read'
var crmReadScopeId = guid(tenant().tenantId, apiUniqueName, crmReadScopeName)
var readerRoleName = 'Reader'
var readerRoleId = guid(tenant().tenantId, apiUniqueName, readerRoleName)
var graphAppId = '00000003-0000-0000-c000-000000000000'
var graphUserReadWriteAllDelegatedId = '204e0828-b5ca-4ad8-b9f3-f32a958e7cc4'
var loopbackUris = ['http://localhost']

resource provisioningApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: '${namePrefix}-Provisioning${uniqueNameSuffix}'
  displayName: '${namePrefix}_PROVISIONING${displayNameSuffix}'
  signInAudience: 'AzureADMyOrg'
  publicClient: {
    redirectUris: loopbackUris
  }
  requiredResourceAccess: [
    {
      resourceAppId: graphAppId
      resourceAccess: [
        {
          id: graphUserReadWriteAllDelegatedId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource apiApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: apiUniqueName
  displayName: '${namePrefix}_API${displayNameSuffix}'
  signInAudience: 'AzureADMyOrg'
  identifierUris: [apiIdentifierUri]
  appRoles: [
    {
      allowedMemberTypes: ['User']
      description: 'Read CRM entries.'
      displayName: readerRoleName
      id: readerRoleId
      isEnabled: true
      value: readerRoleName
    }
  ]
  api: {
    acceptMappedClaims: true
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: crmReadScopeId
        value: crmReadScopeName
        type: 'Admin'
        isEnabled: true
        adminConsentDisplayName: 'Read CRM entries'
        adminConsentDescription: 'Read CRM entries on behalf of the signed-in user.'
      }
    ]
  }
}

resource clientApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: '${namePrefix}-Client${uniqueNameSuffix}'
  displayName: '${namePrefix}_CLIENT${displayNameSuffix}'
  signInAudience: 'AzureADMyOrg'
  publicClient: {
    redirectUris: loopbackUris
  }
  requiredResourceAccess: [
    {
      resourceAppId: apiApp.appId
      resourceAccess: [
        {
          id: crmReadScopeId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource provisioningEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: provisioningApp.appId
}

resource apiEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apiApp.appId
}

resource clientEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: clientApp.appId
}

output provisioningClientId string = provisioningApp.appId
output apiClientId string = apiApp.appId
output clientId string = clientApp.appId
output apiScope string = '${apiIdentifierUri}/${crmReadScopeName}'
output apiDefaultScope string = '${apiIdentifierUri}/.default'
output apiEnterpriseAppObjectId string = apiEnterpriseApp.id
