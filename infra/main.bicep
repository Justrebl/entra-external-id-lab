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
var m2mRoleName = 'CRM.Read.App'
var m2mRoleId = guid(tenant().tenantId, apiUniqueName, m2mRoleName)
var graphAppId = '00000003-0000-0000-c000-000000000000'
var graphUserReadWriteAllDelegatedId = '204e0828-b5ca-4ad8-b9f3-f32a958e7cc4'
var graphGroupMemberReadWriteAllDelegatedId = 'f81125ac-d3b7-4573-a3b2-7099cc39df9e'
var graphApplicationReadAllDelegatedId = 'c79f8feb-a9db-4090-85f9-90d820caa0eb'
var graphAppRoleAssignmentReadWriteAllDelegatedId = '84bccea3-f856-4a8a-967b-dbe0a3d53a64'
var loopbackUris = ['http://localhost']
var customerGroupName = '${namePrefix}-Customers${uniqueNameSuffix}'

resource customerGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: customerGroupName
  displayName: customerGroupName
  description: 'Customers and the M2M service principal for the Entra External ID lab.'
  groupTypes: []
  mailEnabled: false
  mailNickname: '${namePrefix}-CG${uniqueNameSuffix}'
  securityEnabled: true
  members: {
    relationshipSemantics: 'append'
    relationships: [m2mEnterpriseApp.id]
  }
}

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
        {
          id: graphGroupMemberReadWriteAllDelegatedId
          type: 'Scope'
        }
        {
          id: graphApplicationReadAllDelegatedId
          type: 'Scope'
        }
        {
          id: graphAppRoleAssignmentReadWriteAllDelegatedId
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
  groupMembershipClaims: 'SecurityGroup'
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
    {
      allowedMemberTypes: ['Application']
      description: 'Read CRM entries without a signed-in user.'
      displayName: 'Read CRM entries as an application'
      id: m2mRoleId
      isEnabled: true
      value: m2mRoleName
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

resource m2mApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: '${namePrefix}-M2M${uniqueNameSuffix}'
  displayName: '${namePrefix}_M2M${displayNameSuffix}'
  signInAudience: 'AzureADMyOrg'
  isFallbackPublicClient: false
  requiredResourceAccess: [
    {
      resourceAppId: apiApp.appId
      resourceAccess: [
        {
          id: m2mRoleId
          type: 'Role'
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

resource m2mEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: m2mApp.appId
}

resource m2mReaderAssignment 'Microsoft.Graph/appRoleAssignedTo@v1.0' = {
  principalId: m2mEnterpriseApp.id
  resourceId: apiEnterpriseApp.id
  appRoleId: m2mRoleId
}

output provisioningClientId string = provisioningApp.appId
output apiClientId string = apiApp.appId
output clientId string = clientApp.appId
output m2mClientId string = m2mApp.appId
output apiScope string = '${apiIdentifierUri}/${crmReadScopeName}'
output apiDefaultScope string = '${apiIdentifierUri}/.default'
output apiEnterpriseAppObjectId string = apiEnterpriseApp.id
output customerGroupObjectId string = customerGroup.id
