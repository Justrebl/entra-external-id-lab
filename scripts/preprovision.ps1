#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
    throw 'Run this hook from a selected azd environment.'
}

$appSuffix = ([string]$env:APP_SUFFIX).Trim()
if ($appSuffix -and $appSuffix -cnotmatch '^[A-Za-z0-9]{1,20}$') {
    throw 'APP_SUFFIX must contain 1 to 20 letters (A-Z) or digits (0-9).'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Install Azure CLI (az) and reopen PowerShell before running this hook.'
}
az bicep version --only-show-errors 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Bicep is unavailable. Run az bicep upgrade as described in the README prerequisites.'
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

if (-not $appSuffix) {
    $appSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    azd env set APP_SUFFIX $appSuffix --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw 'Could not save APP_SUFFIX in the azd environment; no deployment was started.' }
}

$deploymentName = "entra-lab-apps-$($appSuffix.ToLowerInvariant())"
Write-Host "Deploying the app registrations with suffix $($appSuffix.ToUpperInvariant()) in existing tenant $tenantId..."
$deploymentJson = az deployment tenant create --name $deploymentName --location $location `
    --template-file $template --parameters "appSuffix=$appSuffix" --query properties.outputs --output json
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
foreach ($entry in $settings.GetEnumerator()) {
    azd env set $entry.Key $entry.Value --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw "Could not save $($entry.Key) in the azd environment." }
}
Write-Host "App registrations deployed. Outputs saved to '$env:AZURE_ENV_NAME'."
