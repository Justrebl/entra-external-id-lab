$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    $compiled = az bicep build --file .\infra\main.bicep --stdout
    if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
    $template = $compiled | Out-String | ConvertFrom-Json
    $group = $template.resources.customerGroup
    $members = $group.properties.members
    if ($group.type -ne 'Microsoft.Graph/groups@v1.0' -or
        $group.properties.securityEnabled -ne $true -or $group.properties.mailEnabled -ne $false -or
        $null -eq $group.properties.groupTypes -or $group.properties.groupTypes.Count -ne 0 -or
        $members.relationshipSemantics -cne 'append' -or
        $members.relationships.Count -ne 1 -or
        $members.relationships[0] -ne "[reference('m2mEnterpriseApp').id]" -or
        $group.dependsOn -notcontains 'm2mEnterpriseApp' -or
        $template.outputs.customerGroupObjectId.value -ne "[reference('customerGroup').id]") {
        throw 'Expected the assigned security group to append the M2M service principal, preserve other members, and export its object ID.'
    }

    $api = $template.resources.apiApp.properties
    if ($api.groupMembershipClaims -cne 'SecurityGroup') {
        throw 'Expected the API app registration to emit security group IDs as access-token group claims.'
    }

    $assignment = $template.resources.m2mReaderAssignment
    $role = @($template.resources.apiApp.properties.appRoles | Where-Object allowedMemberTypes -Contains 'Application')
    if ($assignment.type -ne 'Microsoft.Graph/appRoleAssignedTo@v1.0' -or
        $assignment.properties.principalId -ne "[reference('m2mEnterpriseApp').id]" -or
        $assignment.properties.resourceId -ne "[reference('apiEnterpriseApp').id]" -or
        $role.Count -ne 1 -or -not $role[0].isEnabled -or $assignment.properties.appRoleId -ne $role[0].id -or
        $role[0].value -ne "[variables('m2mRoleName')]" -or
        $template.variables.m2mRoleName -cne 'CRM.Read.App') {
        throw 'Expected a direct CRM.Read.App assignment from the standard API to the standard M2M principal.'
    }

    & {
        $env:AZURE_ENV_NAME = 'offline-test'
        $env:APP_PREFIX = 'DEMO'
        $env:APP_SUFFIX = 'TEST'
        $env:ENTRA_TENANT_ID = 'e75fb416-72c7-4910-a3a6-c56d6c0174b3'
        $env:ENTRA_AUTO_CREATE_USER_FLOW = 'false'
        $env:ENTRA_ENABLE_M2M_CLAIMS_LAB = 'false'
        $saved = @{}
        $outputs = @{
            provisioningClientId = @{value = [Guid]::NewGuid().ToString()}
            apiClientId = @{value = [Guid]::NewGuid().ToString()}
            clientId = @{value = [Guid]::NewGuid().ToString()}
            m2mClientId = @{value = [Guid]::NewGuid().ToString()}
            customerGroupObjectId = @{value = [Guid]::NewGuid().ToString()}
            apiScope = @{value = 'api://offline-test/CRM.Read'}
            apiDefaultScope = @{value = 'api://offline-test/.default'}
        }

        function az {
            $global:LASTEXITCODE = 0
            switch ($args[0..1] -join ' ') {
                'bicep version' { return }
                'account show' { return $env:ENTRA_TENANT_ID }
                'deployment tenant' { return ($outputs | ConvertTo-Json -Depth 3) }
                default { throw "Unexpected Azure CLI call: $args" }
            }
        }

        function azd {
            if (($args[0..1] -join ' ') -ne 'env set' -or $args[5] -ne 'offline-test') {
                throw "Unexpected azd call: $args"
            }
            $saved[$args[2]] = $args[3]
            $global:LASTEXITCODE = 0
        }

        & .\scripts\preprovision.ps1
        if ($saved.ENTRA_CUSTOMER_GROUP_ID -ne $outputs.customerGroupObjectId.value) {
            throw 'The hook did not save the deployed group object ID to the selected azd environment.'
        }

        $saved.Clear()
        $outputs.customerGroupObjectId.value = [Guid]::Empty.ToString()
        try {
            & .\scripts\preprovision.ps1
            throw 'The hook accepted an invalid customer group object ID.'
        } catch {
            if ($_.Exception.Message -notlike '*did not return a valid customer security group object ID*' -or $saved.Count) {
                throw
            }
        }
    }
    Write-Host 'Offline Bicep and preprovision checks passed.'
} finally {
    Pop-Location
}
