targetScope = 'tenant'

extension microsoftGraphV1

@minLength(1)
@maxLength(38)
param namePrefix string

@minLength(1)
@maxLength(20)
param appSuffix string

var suffix = toUpper(appSuffix)
var apiName = '${namePrefix}-ClaimsApi-${suffix}'
var apiUri = 'api://${tenant().tenantId}/${apiName}'
var roleId = guid(tenant().tenantId, apiName, 'CRM.Read.App')

resource claimsApi 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: apiName
  displayName: '${namePrefix}_CLAIMS_API_${suffix}'
  signInAudience: 'AzureADMyOrg'
  identifierUris: [apiUri]
  appRoles: [
    {
      allowedMemberTypes: ['Application']
      description: 'Read CRM entries in the isolated claims lab.'
      displayName: 'Read CRM entries as an application'
      id: roleId
      isEnabled: true
      value: 'CRM.Read.App'
    }
  ]
  api: {
    acceptMappedClaims: true
    requestedAccessTokenVersion: 2
  }
}

resource claimsClient 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: '${namePrefix}-ClaimsM2M-${suffix}'
  displayName: '${namePrefix}_CLAIMS_M2M_${suffix}'
  signInAudience: 'AzureADMyOrg'
  isFallbackPublicClient: false
  requiredResourceAccess: [
    {
      resourceAppId: claimsApi.appId
      resourceAccess: [
        {
          id: roleId
          type: 'Role'
        }
      ]
    }
  ]
}

resource claimsApiEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: claimsApi.appId
}

resource claimsClientEnterpriseApp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: claimsClient.appId
  tags: ['customer:LAB-A']
}

output apiClientId string = claimsApi.appId
output apiEnterpriseAppObjectId string = claimsApiEnterpriseApp.id
output m2mClientId string = claimsClient.appId
output apiDefaultScope string = '${apiUri}/.default'
