#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-GraphCollection([string]$Uri) {
    while ($Uri) {
        $pageUri = [Uri]$Uri
        if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -ne 'https' -or
            $pageUri.Host -ne 'graph.microsoft.com' -or -not $pageUri.IsDefaultPort -or $pageUri.UserInfo) {
            throw 'Microsoft Graph returned an unexpected pagination URL.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable
        if ($null -eq $page -or -not $page.ContainsKey('value')) {
            throw 'Microsoft Graph did not return a collection.'
        }
        $page.value
        $Uri = $page['@odata.nextLink']
    }
}

function Set-LabUserFlow([string]$FlowName, [Guid]$ClientId) {
    $flowsUri = 'https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows'
    $flowType = 'microsoft.graph.externalUsersSelfServiceSignUpEventsFlow'
    $flowMarker = 'Created by the Entra External ID lab hook.'
    $signInOnly = @{
        '@odata.type' = '#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp'
        isSignUpAllowed = $false
    }
    $appFilter = [Uri]::EscapeDataString(
        "$flowType/conditions/applications/includeApplications/any(app:app/appId eq '$ClientId')"
    )
    Write-Host 'Checking for a user flow already linked to the lab client...'
    $assigned = @(Get-GraphCollection -Uri "${flowsUri}?`$filter=$appFilter")
    if ($assigned.Count -gt 1) {
        throw 'More than one user flow was returned for the client. Check its assignments in Entra.'
    }
    $candidates = $assigned
    if (-not $assigned.Count) {
        $candidates = @(Get-GraphCollection -Uri $flowsUri | Where-Object { $_.displayName -eq $FlowName })
        if ($candidates.Count -gt 1) {
            throw "Multiple user flows are named '$FlowName'. Choose another APP_PREFIX or APP_SUFFIX."
        }
    }

    if (-not $candidates.Count) {
        Write-Host "Creating sign-in-only user flow '$FlowName'..."
        $body = @{
            '@odata.type' = "#$flowType"
            displayName = $FlowName
            description = $flowMarker
            onAuthenticationMethodLoadStart = @{
                '@odata.type' = '#microsoft.graph.onAuthenticationMethodLoadStartExternalUsersSelfServiceSignUp'
                identityProviders = @(@{ id = 'EmailPassword-OAUTH' })
            }
            onInteractiveAuthFlowStart = $signInOnly
        } | ConvertTo-Json -Depth 8 -Compress
        $flow = Invoke-MgGraphRequest -Method POST -Uri $flowsUri -Body $body `
            -ContentType 'application/json' -OutputType Hashtable
        if ($flow.onInteractiveAuthFlowStart.isSignUpAllowed -cne $false -or
            $flow.onInteractiveAuthFlowStart.isSignUpAllowed -isnot [bool]) {
            throw 'Microsoft Graph did not confirm sign-up is disabled on the new flow. No app was linked.'
        }
        $flowId = $flow.id
    } else {
        $flowId = $candidates[0].id
    }
    if ([string]::IsNullOrWhiteSpace($flowId)) {
        throw 'Microsoft Graph did not return a user flow ID.'
    }

    $flowUri = "$flowsUri/$([Uri]::EscapeDataString($flowId))"
    $appsUri = "$flowUri/conditions/applications/includeApplications"
    if ($candidates.Count) {
        $flow = Invoke-MgGraphRequest -Method GET -Uri $flowUri -OutputType Hashtable
        if ($flow.value) {
            $flow = $flow.value
        }
        if ($null -eq $flow -or $flow.id -ne $flowId -or $flow['@odata.type'] -ne "#$flowType") {
            throw 'Microsoft Graph did not return the expected External ID user flow.'
        }

        $isLabFlow = $flow.displayName -eq $FlowName -and $flow.description -eq $flowMarker
        if (-not $assigned.Count -and -not $isLabFlow) {
            throw "A user flow named '$FlowName' is not managed by this hook. Choose another APP_PREFIX or APP_SUFFIX."
        }
        $allowsSignUp = $flow.onInteractiveAuthFlowStart.isSignUpAllowed
        if ($allowsSignUp -isnot [bool] -or $allowsSignUp) {
            if (-not $isLabFlow) {
                throw 'The client is linked to an unmanaged flow that is not verified as sign-in only. Configure it manually.'
            }
            $otherApps = @(Get-GraphCollection -Uri $appsUri | Where-Object { $_.appId -ne $ClientId.ToString() })
            if ($otherApps.Count) {
                throw 'The lab user flow is shared with other apps. The hook will not change its sign-up setting.'
            }
            $body = @{
                '@odata.type' = "#$flowType"
                onInteractiveAuthFlowStart = $signInOnly
            } | ConvertTo-Json -Depth 4 -Compress
            Write-Host 'Disabling self-service sign-up on the dedicated lab user flow...'
            Invoke-MgGraphRequest -Method PATCH -Uri $flowUri -Body $body -ContentType 'application/json' | Out-Null
        }
    }

    if (-not $assigned.Count) {
        Write-Host 'Linking the lab client to the sign-in-only user flow...'
        $body = @{
            '@odata.type' = '#microsoft.graph.authenticationConditionApplication'
            appId = $ClientId.ToString()
        } | ConvertTo-Json -Compress
        Invoke-MgGraphRequest -Method POST -Uri $appsUri -Body $body -ContentType 'application/json' | Out-Null
    }
    return $flowId
}

function Set-LabM2MClaimsPolicy([Guid]$ApiObjectId, [Guid]$ApiClientId) {
    $policiesUri = 'https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies'
    $apiUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$ApiObjectId"
    $assignmentsUri = "$apiUri/claimsMappingPolicies"
    $policyName = "EntraLab-M2MClaims-$ApiObjectId"
    $definition = @{
        ClaimsMappingPolicy = @{
            Version = 1
            IncludeBasicClaimSet = 'true'
            ClaimsSchema = @(@{
                Source = 'application'
                ID = 'tags'
                JwtClaimType = 'm2m_customer_tag'
            })
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $api = Invoke-MgGraphRequest -Method GET -Uri "${apiUri}?`$select=id,appId" -OutputType Hashtable
    if ($api.id -ne $ApiObjectId.ToString() -or $api.appId -ne $ApiClientId.ToString()) {
        throw 'Graph did not confirm the isolated API service principal. No claims policy was changed.'
    }

    Write-Host 'Checking claims policies on the isolated API...'
    $assigned = @(Get-GraphCollection -Uri $assignmentsUri)
    if ($assigned.Count -gt 1 -or ($assigned.Count -eq 1 -and $assigned[0].displayName -cne $policyName)) {
        throw 'The isolated API has an unexpected claims policy. The hook will not replace it.'
    }
    $policies = $assigned
    if (-not $assigned.Count) {
        $filter = [Uri]::EscapeDataString("displayName eq '$policyName'")
        $policies = @(Get-GraphCollection -Uri "${policiesUri}?`$filter=$filter" |
            Where-Object { $_.displayName -ceq $policyName })
        if ($policies.Count -gt 1) {
            throw 'Multiple matching claims policies exist. The hook will not choose one.'
        }
    }

    if ($policies.Count) {
        $policy = $policies[0]
        $stored = @($policy.definition)
        if ($stored.Count -ne 1 -or [string]::IsNullOrWhiteSpace($stored[0]) -or $policy.isOrganizationDefault -ne $false) {
            throw 'The existing claims policy is not the expected non-default lab policy.'
        }
        $parsed = $stored[0] | ConvertFrom-Json -AsHashtable
        $rules = $parsed.ClaimsMappingPolicy
        $claims = @($rules.ClaimsSchema)
        if ($parsed.Count -ne 1 -or $rules.Count -ne 3 -or $rules.Version -ne 1 -or
            -not [string]::Equals($rules.IncludeBasicClaimSet, 'true', [StringComparison]::OrdinalIgnoreCase) -or
            $claims.Count -ne 1 -or $claims[0].Count -ne 3 -or $claims[0].Source -cne 'application' -or
            $claims[0].ID -cne 'tags' -or $claims[0].JwtClaimType -cne 'm2m_customer_tag') {
            throw 'The existing claims policy has a different definition. The hook will not modify or attach it.'
        }
    } else {
        Write-Host 'Creating the lab claims-mapping policy...'
        $body = @{
            displayName = $policyName
            definition = @($definition)
            isOrganizationDefault = $false
        } | ConvertTo-Json -Compress
        $policy = Invoke-MgGraphRequest -Method POST -Uri $policiesUri -Body $body `
            -ContentType 'application/json' -OutputType Hashtable
    }

    $policyId = [Guid]::Empty
    if (-not [Guid]::TryParse($policy.id, [ref]$policyId) -or $policyId -eq [Guid]::Empty) {
        throw 'Microsoft Graph did not return a valid claims policy ID.'
    }
    if (-not $assigned.Count) {
        Write-Host 'Attaching the claims-mapping policy to the isolated API...'
        $body = @{ '@odata.id' = "$policiesUri/$policyId" } | ConvertTo-Json -Compress
        Invoke-MgGraphRequest -Method POST -Uri "$assignmentsUri/`$ref" -Body $body `
            -ContentType 'application/json' | Out-Null
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            if ($attempt) { Start-Sleep -Seconds 2 }
            $assigned = @(Get-GraphCollection -Uri $assignmentsUri)
            if ($assigned.Count) { break }
        }
        if ($assigned.Count -ne 1 -or $assigned[0].id -ne $policyId.ToString()) {
            throw 'Graph did not confirm the expected policy assignment. Check the isolated API before testing.'
        }
    }
    return $policyId.ToString()
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
    throw 'Run this hook from a selected azd environment.'
}
Write-Host 'Starting preprovision for the selected azd environment.'

$appPrefix = ([string]$env:APP_PREFIX).Trim()
$saveAppPrefix = -not $appPrefix
if ($saveAppPrefix) {
    Write-Host 'APP_PREFIX is not set. Your choice will be saved before deployment.'
    $appPrefix = ([string](Read-Host 'App registration prefix (for example, DEMO)')).Trim()
}
if ($appPrefix -cnotmatch '^[A-Za-z0-9]{1,38}$') {
    throw 'APP_PREFIX must contain 1 to 38 ASCII letters or digits.'
}
$appPrefix = $appPrefix.ToUpperInvariant()
if (-not $saveAppPrefix) {
    Write-Host "Reusing APP_PREFIX '$appPrefix'."
}

$appSuffix = ([string]$env:APP_SUFFIX).Trim()
if ($appSuffix -and $appSuffix -cnotmatch '^[A-Za-z0-9]{1,20}$') {
    throw 'APP_SUFFIX must contain 1 to 20 letters (A-Z) or digits (0-9).'
}

$flowOption = ([string]$env:ENTRA_AUTO_CREATE_USER_FLOW).Trim()
if ($flowOption -and $flowOption -notin @('true', 'false')) {
    throw 'ENTRA_AUTO_CREATE_USER_FLOW must be true or false. Leave it unset for manual setup.'
}
$autoCreateUserFlow = $flowOption -eq 'true'
$claimsOption = ([string]$env:ENTRA_ENABLE_M2M_CLAIMS_LAB).Trim()
if ($claimsOption -and $claimsOption -notin @('true', 'false')) {
    throw 'ENTRA_ENABLE_M2M_CLAIMS_LAB must be true or false. Leave it unset to skip the claims experiment.'
}
$enableM2MClaimsLab = $claimsOption -eq 'true'
$graphScopes = @()
if ($autoCreateUserFlow) {
    $graphScopes += 'EventListener.ReadWrite.All'
    Write-Host 'User flow mode: automatic (Microsoft Graph).'
} else {
    Write-Host 'User flow mode: manual. The hook will not change user flows.'
}
if ($enableM2MClaimsLab) {
    $graphScopes += @('Policy.Read.All', 'Policy.ReadWrite.ApplicationConfiguration', 'Application.ReadWrite.All')
    Write-Host 'M2M claims experiment enabled for a separate API and confidential client.'
}

Write-Host 'Checking Azure CLI and Bicep prerequisites...'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Install Azure CLI (az) and reopen PowerShell before running this hook.'
}
az bicep version --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Bicep is unavailable. Run az bicep upgrade as described in the README prerequisites.'
}
if ($graphScopes.Count) {
    Write-Host 'Checking the Microsoft Graph PowerShell module...'
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Install Microsoft.Graph.Authentication as described in the README, or turn off the opt-in Graph features.'
    }
    Import-Module Microsoft.Graph.Authentication
}

$tenantInput = $env:ENTRA_TENANT_ID
if ([string]::IsNullOrWhiteSpace($tenantInput)) {
    $tenantInput = Read-Host 'Directory (tenant) ID of the existing Entra tenant'
}
$tenantId = [Guid]::Empty
if (-not [Guid]::TryParseExact(([string]$tenantInput).Trim(), 'D', [ref]$tenantId) -or $tenantId -eq [Guid]::Empty) {
    throw 'ENTRA_TENANT_ID must be the Directory (tenant) ID of an existing Entra tenant.'
}

$location = 'westeurope'
if (-not [string]::IsNullOrWhiteSpace($env:AZURE_LOCATION)) {
    $location = $env:AZURE_LOCATION.Trim()
}

$template = Join-Path $PWD.Path 'infra\main.bicep'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
    throw 'Run the hook from the lab folder containing infra\main.bicep.'
}
$claimsTemplate = Join-Path $PWD.Path 'infra\m2m-claims.bicep'
if ($enableM2MClaimsLab -and -not (Test-Path -LiteralPath $claimsTemplate -PathType Leaf)) {
    throw 'The isolated M2M claims Bicep template is missing.'
}

Write-Host 'Checking the Azure CLI sign-in for the requested tenant...'
$activeTenant = az account show --query tenantId --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenantId.ToString()) {
    Write-Host 'Signing in to the requested tenant with Azure CLI...'
    az login --tenant ($tenantId.ToString()) --allow-no-subscriptions --output none
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed; no deployment was started.' }
}
$activeTenant = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenantId.ToString()) {
    throw 'Azure CLI is not connected to the requested tenant; no deployment was started.'
}
Write-Host 'Verified the Azure CLI tenant.'

if ($graphScopes.Count) {
    Write-Warning 'First Graph consent can add the Microsoft Graph Command Line Tools enterprise application to this tenant.'
    Write-Host 'Sign in to Microsoft Graph in your browser to authorize the selected opt-in features...'
    Connect-MgGraph -TenantId ($tenantId.ToString()) -Scopes $graphScopes -Environment Global -ContextScope Process -NoWelcome
    $graphContext = Get-MgContext
    $missingScopes = @($graphScopes | Where-Object { $graphContext.Scopes -notcontains $_ })
    if ($graphContext.TenantId -ne $tenantId.ToString() -or $graphContext.AuthType -ne 'Delegated' -or
        $missingScopes.Count) {
        throw 'Microsoft Graph must use delegated sign-in to the requested tenant with all scopes for the selected features; no deployment was started.'
    }
    Write-Host 'Verified Microsoft Graph tenant and delegated permission.'
}

if ($saveAppPrefix) {
    Write-Host "Saving APP_PREFIX '$appPrefix' in the azd environment..."
    azd env set APP_PREFIX $appPrefix --environment $env:AZURE_ENV_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not save APP_PREFIX in the azd environment; no deployment was started.' }
}
if (-not $appSuffix) {
    $appSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    Write-Host "Generated APP_SUFFIX '$appSuffix'. Saving it in the azd environment..."
    azd env set APP_SUFFIX $appSuffix --environment $env:AZURE_ENV_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not save APP_SUFFIX in the azd environment; no deployment was started.' }
} else {
    Write-Host "Reusing APP_SUFFIX '$($appSuffix.ToUpperInvariant())'."
}

$appNameSuffix = $appSuffix.ToUpperInvariant()
$deploymentPrefix = if ($appPrefix -eq 'DEMO') { 'entra-lab' } else { $appPrefix.ToLowerInvariant() }
$deploymentName = "$deploymentPrefix-apps-$($appSuffix.ToLowerInvariant())"
Write-Host "Deploying lab apps, the ${appPrefix}-Customers-$appNameSuffix security group, and the M2M API role assignment..."
$deploymentJson = az deployment tenant create --name $deploymentName --location $location `
    --template-file $template --parameters "namePrefix=$appPrefix" "appSuffix=$appSuffix" `
    --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw 'Entra lab deployment failed; see the Azure CLI error above.' }

$outputs = $deploymentJson | Out-String | ConvertFrom-Json
$settings = [ordered]@{
    ENTRA_TENANT_ID          = $tenantId.ToString()
    AZURE_LOCATION           = $location
    ENTRA_PROVISION_CLIENT_ID = $outputs.provisioningClientId.value
    ENTRA_API_APP_ID          = $outputs.apiClientId.value
    ENTRA_CLIENT_ID           = $outputs.clientId.value
    ENTRA_M2M_CLIENT_ID       = $outputs.m2mClientId.value
    ENTRA_CUSTOMER_GROUP_ID   = $outputs.customerGroupObjectId.value
    ENTRA_API_SCOPE           = $outputs.apiScope.value
    ENTRA_API_DEFAULT_SCOPE   = $outputs.apiDefaultScope.value
}
foreach ($entry in $settings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        throw "The deployment did not return a value for $($entry.Key); environment outputs were not saved."
    }
}
$clientId = [Guid]::Empty
if (-not [Guid]::TryParse($settings.ENTRA_CLIENT_ID, [ref]$clientId) -or $clientId -eq [Guid]::Empty) {
    throw 'The deployment did not return a valid client application ID.'
}
$m2mClientId = [Guid]::Empty
if (-not [Guid]::TryParse($settings.ENTRA_M2M_CLIENT_ID, [ref]$m2mClientId) -or
    $m2mClientId -eq [Guid]::Empty -or $m2mClientId -eq $clientId) {
    throw 'The deployment did not return a valid, separate M2M client application ID.'
}
$customerGroupId = [Guid]::Empty
if (-not [Guid]::TryParse($settings.ENTRA_CUSTOMER_GROUP_ID, [ref]$customerGroupId) -or
    $customerGroupId -eq [Guid]::Empty) {
    throw 'The deployment did not return a valid customer security group object ID; environment outputs were not saved.'
}
Write-Host 'Bicep deployment complete. Saving lab outputs...'
foreach ($entry in $settings.GetEnumerator()) {
    azd env set $entry.Key $entry.Value --environment $env:AZURE_ENV_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not save $($entry.Key) in the azd environment." }
}
Write-Host 'Lab outputs saved to the selected azd environment.'

if ($autoCreateUserFlow) {
    $flowName = "LabSignIn-$appPrefix-$appNameSuffix"
    $userFlowId = Set-LabUserFlow -FlowName $flowName -ClientId $clientId
    Write-Host 'Saving the user flow output to the selected azd environment...'
    azd env set ENTRA_USER_FLOW_ID $userFlowId --environment $env:AZURE_ENV_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not save ENTRA_USER_FLOW_ID in the azd environment.' }
    Write-Host 'The client is linked to a sign-in-only user flow. ENTRA_USER_FLOW_ID was saved.'
} else {
    Write-Host 'User flow setup was skipped. Follow the manual steps in the README.'
}

if ($enableM2MClaimsLab) {
    $baselineApiObjectId = [Guid]::Empty
    $baselineApiClientId = [Guid]::Empty
    $provisioningClientId = [Guid]::Empty
    if (-not [Guid]::TryParse($outputs.apiEnterpriseAppObjectId.value, [ref]$baselineApiObjectId) -or
        -not [Guid]::TryParse($settings.ENTRA_API_APP_ID, [ref]$baselineApiClientId) -or
        -not [Guid]::TryParse($settings.ENTRA_PROVISION_CLIENT_ID, [ref]$provisioningClientId) -or
        $baselineApiObjectId -eq [Guid]::Empty -or $baselineApiClientId -eq [Guid]::Empty -or
        $provisioningClientId -eq [Guid]::Empty) {
        throw 'The original lab app IDs could not be verified. The claims experiment was not started.'
    }

    $claimsDeploymentName = "$deploymentPrefix-clm-$($appSuffix.ToLowerInvariant())"
    Write-Host "Deploying the isolated claims API and M2M client: ${appPrefix}_CLAIMS_API_$appNameSuffix and ${appPrefix}_CLAIMS_M2M_$appNameSuffix..."
    $claimsJson = az deployment tenant create --name $claimsDeploymentName --location $location `
        --template-file $claimsTemplate --parameters "namePrefix=$appPrefix" "appSuffix=$appSuffix" `
        --query properties.outputs --output json
    if ($LASTEXITCODE -ne 0) { throw 'Isolated M2M claims deployment failed; see the Azure CLI error above.' }

    $claims = $claimsJson | Out-String | ConvertFrom-Json
    $claimsApiObjectId = [Guid]::Empty
    $claimsApiClientId = [Guid]::Empty
    $claimsClientId = [Guid]::Empty
    $baselineClientIds = @($baselineApiClientId, $clientId, $m2mClientId, $provisioningClientId)
    $expectedScope = "api://$tenantId/$appPrefix-ClaimsApi-$appNameSuffix/.default"
    if (-not [Guid]::TryParse($claims.apiEnterpriseAppObjectId.value, [ref]$claimsApiObjectId) -or
        -not [Guid]::TryParse($claims.apiClientId.value, [ref]$claimsApiClientId) -or
        -not [Guid]::TryParse($claims.m2mClientId.value, [ref]$claimsClientId) -or
        $claimsApiObjectId -eq [Guid]::Empty -or $claimsApiClientId -eq [Guid]::Empty -or $claimsClientId -eq [Guid]::Empty -or
        $claimsApiObjectId -eq $baselineApiObjectId -or $claimsApiClientId -in $baselineClientIds -or
        $claimsClientId -in $baselineClientIds -or $claimsClientId -eq $claimsApiClientId -or
        $claims.apiDefaultScope.value -cne $expectedScope) {
        throw 'The deployment did not return distinct claims-lab apps and the expected API scope. No claims policy was changed.'
    }

    $claimsSettings = [ordered]@{
        ENTRA_M2M_CLAIMS_POLICY_ID         = Set-LabM2MClaimsPolicy -ApiObjectId $claimsApiObjectId -ApiClientId $claimsApiClientId
        ENTRA_M2M_CLAIMS_CLIENT_ID         = $claimsClientId.ToString()
        ENTRA_M2M_CLAIMS_API_DEFAULT_SCOPE = $claims.apiDefaultScope.value
    }
    Write-Host 'Saving the isolated claims-lab outputs...'
    foreach ($entry in $claimsSettings.GetEnumerator()) {
        azd env set $entry.Key $entry.Value --environment $env:AZURE_ENV_NAME | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not save $($entry.Key) in the azd environment." }
    }
    Write-Host 'Claims policy configured. Grant CRM.Read.App admin consent and create the isolated client secret in the Entra portal.'
}
