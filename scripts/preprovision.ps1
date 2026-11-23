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
            Invoke-MgGraphRequest -Method PATCH -Uri $flowUri -Body $body -ContentType 'application/json' | Out-Null
        }
    }

    if (-not $assigned.Count) {
        $body = @{
            '@odata.type' = '#microsoft.graph.authenticationConditionApplication'
            appId = $ClientId.ToString()
        } | ConvertTo-Json -Compress
        Invoke-MgGraphRequest -Method POST -Uri $appsUri -Body $body -ContentType 'application/json' | Out-Null
    }
    return $flowId
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
    throw 'Run this hook from a selected azd environment.'
}

$appPrefix = ([string]$env:APP_PREFIX).Trim()
if (-not $appPrefix) {
    throw 'APP_PREFIX is required. Set it with azd env set APP_PREFIX DEMO before running the hook.'
}
if ($appPrefix -cnotmatch '^[A-Za-z0-9]{1,38}$') {
    throw 'APP_PREFIX must contain 1 to 38 ASCII letters or digits.'
}
$appPrefix = $appPrefix.ToUpperInvariant()

$appSuffix = ([string]$env:APP_SUFFIX).Trim()
if ($appSuffix -and $appSuffix -cnotmatch '^[A-Za-z0-9]{1,20}$') {
    throw 'APP_SUFFIX must contain 1 to 20 letters (A-Z) or digits (0-9).'
}

$flowOption = ([string]$env:ENTRA_AUTO_CREATE_USER_FLOW).Trim()
if ($flowOption -and $flowOption -notin @('true', 'false')) {
    throw 'ENTRA_AUTO_CREATE_USER_FLOW must be true or false. Leave it unset for manual setup.'
}
$autoCreateUserFlow = $flowOption -eq 'true'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Install Azure CLI (az) and reopen PowerShell before running this hook.'
}
az bicep version --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Bicep is unavailable. Run az bicep upgrade as described in the README prerequisites.'
}
if ($autoCreateUserFlow) {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Install Microsoft.Graph.Authentication as described in the README, or unset ENTRA_AUTO_CREATE_USER_FLOW.'
    }
    Import-Module Microsoft.Graph.Authentication
}

$tenantInput = $env:ENTRA_TENANT_ID
if ([string]::IsNullOrWhiteSpace($tenantInput)) {
    $tenantInput = Read-Host 'Directory (tenant) ID of the existing Entra tenant'
}
$tenantId = [Guid]::Empty
if (-not [Guid]::TryParseExact($tenantInput.Trim(), 'D', [ref]$tenantId) -or $tenantId -eq [Guid]::Empty) {
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

$activeTenant = az account show --query tenantId --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenantId.ToString()) {
    az login --tenant ($tenantId.ToString()) --allow-no-subscriptions --output none
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed; no deployment was started.' }
}
$activeTenant = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenantId.ToString()) {
    throw 'Azure CLI is not connected to the requested tenant; no deployment was started.'
}

if ($autoCreateUserFlow) {
    $flowScope = 'EventListener.ReadWrite.All'
    Write-Warning 'First Graph consent can add the Microsoft Graph Command Line Tools enterprise application to this tenant.'
    Connect-MgGraph -TenantId ($tenantId.ToString()) -Scopes $flowScope -Environment Global -ContextScope Process -NoWelcome
    $graphContext = Get-MgContext
    if ($graphContext.TenantId -ne $tenantId.ToString() -or $graphContext.AuthType -ne 'Delegated' -or
        $graphContext.Scopes -notcontains $flowScope) {
        throw "Microsoft Graph must use a delegated sign-in to the requested tenant with $flowScope; no deployment was started."
    }
}

if (-not $appSuffix) {
    $appSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    azd env set APP_SUFFIX $appSuffix --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw 'Could not save APP_SUFFIX in the azd environment; no deployment was started.' }
}

$deploymentPrefix = if ($appPrefix -eq 'DEMO') { 'entra-lab' } else { $appPrefix.ToLowerInvariant() }
$deploymentName = "$deploymentPrefix-apps-$($appSuffix.ToLowerInvariant())"
Write-Host "Deploying app registrations with prefix $appPrefix and suffix $($appSuffix.ToUpperInvariant()) in existing tenant $tenantId..."
$deploymentJson = az deployment tenant create --name $deploymentName --location $location `
    --template-file $template --parameters "namePrefix=$appPrefix" "appSuffix=$appSuffix" `
    --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw 'Entra app deployment failed; see the Azure CLI error above.' }

$outputs = $deploymentJson | Out-String | ConvertFrom-Json
$settings = [ordered]@{
    ENTRA_TENANT_ID          = $tenantId.ToString()
    AZURE_LOCATION           = $location
    ENTRA_PROVISION_CLIENT_ID = $outputs.provisioningClientId.value
    ENTRA_API_APP_ID          = $outputs.apiClientId.value
    ENTRA_CLIENT_ID           = $outputs.clientId.value
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
foreach ($entry in $settings.GetEnumerator()) {
    azd env set $entry.Key $entry.Value --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw "Could not save $($entry.Key) in the azd environment." }
}
Write-Host "App registrations deployed. Outputs saved to '$env:AZURE_ENV_NAME'."

if ($autoCreateUserFlow) {
    $flowName = "LabSignIn-$appPrefix-$($appSuffix.ToUpperInvariant())"
    $userFlowId = Set-LabUserFlow -FlowName $flowName -ClientId $clientId
    azd env set ENTRA_USER_FLOW_ID $userFlowId --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw 'Could not save ENTRA_USER_FLOW_ID in the azd environment.' }
    Write-Host 'The client is linked to a sign-in-only user flow. ENTRA_USER_FLOW_ID was saved.'
} else {
    Write-Host 'User flow setup was skipped. Follow the manual steps in the README.'
}
