# Entra External ID app registrations

The tenant-scoped template creates three single-tenant app registrations and their enterprise applications in an **existing** tenant. It cannot create a tenant, creates no secrets, and does not grant consent.

| Registration | Configuration |
| --- | --- |
| `DEMO_PROVISIONING` | Desktop loopback `http://localhost`; declares delegated Microsoft Graph `User.ReadWrite.All` for customer management and `Application.Read.All` and `AppRoleAssignment.ReadWrite.All` for role assignment. |
| `DEMO_API` | Exposes admin-consent-only `CRM.Read` and the `Reader` user app role; issues v2 access tokens and accepts mapped claims. |
| `DEMO_CLIENT` | Desktop loopback `http://localhost`; requests delegated `CRM.Read` from `DEMO_API`. |

## Deploy

For the azd workflow, see the [lab guide](../README.md). To deploy directly, run these commands from `infra` using Azure CLI and Bicep 0.36.1 or later. The deploying identity needs permission to create or update Entra applications and service principals and run ARM deployments at tenant scope (`/`). See [tenant deployment without an Azure subscription](https://learn.microsoft.com/en-us/graph/templates/bicep/how-to-deploy-without-azure-sub) and [Graph deployment permissions](https://learn.microsoft.com/en-us/graph/templates/bicep/concept-permissions-and-privileges).

```powershell
$tenantId = [Guid]::Empty
$tenantInput = (Read-Host "Directory (tenant) ID of the existing external tenant").Trim()
if (-not [Guid]::TryParseExact($tenantInput, 'D', [ref]$tenantId) -or $tenantId -eq [Guid]::Empty) {
    throw "Provide the Directory (tenant) ID of an existing tenant."
}
az login --tenant ($tenantId.ToString()) --allow-no-subscriptions
if ($LASTEXITCODE -ne 0) { throw "Azure CLI sign-in failed." }
$activeTenant = az account show --query tenantId -o tsv
if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenantId.ToString()) {
    throw "Azure CLI is not connected to the expected tenant."
}
az deployment tenant create --name entra-lab-apps --location westeurope --template-file .\main.bicep --query properties.outputs
```

Use the returned `apiScope` or `apiDefaultScope` exactly as returned. The application ID URI uses the tenant ID and API name; the `aud` claim in a v2 access token is the API's application (client) ID, returned as `apiClientId`.

The azd hook prompts for `APP_PREFIX` if missing (1 to 38 ASCII letters or digits) and saves it. It generates and saves a random `APP_SUFFIX` unless you set one with `azd env set APP_SUFFIX DEV` (1 to 20 ASCII letters or digits). Run the [preprovision hook](../scripts/preprovision.ps1) with `azd hooks run preprovision`, not `azd up` or `azd provision`; built-in provisioning does not support this tenant-scoped template. If deployment reports `AuthorizationFailed`, check Azure RBAC at `/`.

The direct Azure CLI command defaults to `DEMO` with unsuffixed names. To reuse hook-created apps, pass matching uppercase values, for example `--parameters namePrefix=DEMO appSuffix=DEV`. Keep both values stable: they determine the app names, API identifier URI, and `Reader` role ID. Bicep identifies registrations by `uniqueName`, not display name.

## Finish the tenant setup

Use the suffixed app names below if you set a suffix.

1. In **App registrations > API permissions**, review and grant admin consent separately on `DEMO_CLIENT` and `DEMO_PROVISIONING` for the delegated permissions listed above. The template declares but does not grant them. Keep Microsoft Graph provisioning permissions off the customer-facing client and use the provisioning CLI only as an authorized operator.
2. Follow the [manual user flow setup](../README.md#manual-user-flow-setup-default): set up an **Email with password** flow, disable sign-up, and link only `DEMO_CLIENT`. Leave `DEMO_PROVISIONING` out of the customer flow; it uses a tenant administrative sign-in. The azd hook configures the flow only when you opt in.
3. On the **DEMO_API enterprise application**, under **Single sign-on > Attributes & Claims**, add `Customer_Label` via **Directory schema extension > b2c-extensions-app**. Use an existing attribute and a test user with a populated value. If the claim is used for access control, map a separately provisioned `customer_id` that customers cannot set or edit; don't authorize on a self-entered label. See [Add attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token).

The template does not deploy the flow, claim mapping, or role assignment. `create-user` assigns `Reader` by default; for existing customers, assign it under **Users and groups** on the API enterprise application.

## Use the CLI

From the repository root, run the CLI with the .NET 10 SDK. Use your tenant authority and the `clientId` and `apiScope` from the deployment output. The CLI prints the decoded access-token claims without printing the raw token.

```powershell
$cliId = Read-Host "clientId from the deployment"
$scope = Read-Host "apiScope from the deployment"
$authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/"
dotnet run --project .\EntraTokenDemo -- $cliId $authority $scope
```

For `create-user` and `update-user`, set `ENTRA_PROVISION_CLIENT_ID` to the `provisioningClientId` output and `ENTRA_EXTENSIONS_APP_ID` to the existing `b2c-extensions-app` application (client) ID. For automatic role assignment, also set `ENTRA_API_APP_ID` to `apiClientId`. With `create-user --no-role` or `update-user`, the CLI requests only `User.ReadWrite.All`. See the [CLI walkthrough](../README.md#4-set-a-customer-label-and-inspect-the-token).
