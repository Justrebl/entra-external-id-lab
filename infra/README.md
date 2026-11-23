# Entra External ID app registrations

The tenant-scoped template creates three single-tenant app registrations and their enterprise applications in an **existing** tenant. It cannot create a tenant, creates no secrets, and does not grant consent.

| Registration | Configuration |
| --- | --- |
| `DEMO_PROVISIONING` | Desktop loopback `http://localhost`; requests delegated Microsoft Graph `User.ReadWrite.All` for `create-user`. |
| `DEMO_API` | Exposes admin-consent-only `CRM.Read`; issues v2 access tokens and accepts mapped claims. |
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

The azd hook generates and saves a random `APP_SUFFIX` if none is configured. The direct Azure CLI command above uses unsuffixed names unless you pass `--parameters appSuffix=DEV`; if you pass a suffix, also use a distinct deployment name (for example, `entra-lab-apps-dev`). Use 1 to 20 ASCII letters or digits. The suffix changes the app names, `uniqueName` values, and API identifier URI. Keep `namePrefix` and the suffix stable on redeployment. The template identifies registrations by `uniqueName`, not display name; it does not automatically adopt apps created in the portal.

## Finish the tenant setup

Use the suffixed app names below if you set a suffix.

1. In **App registrations > API permissions**, review and grant admin consent separately for `DEMO_CLIENT` (`CRM.Read`) and `DEMO_PROVISIONING` (`User.ReadWrite.All`). Keep this provisioning permission off the customer-facing client and sign in to the provisioning CLI only as an authorized operator.
2. Add only `DEMO_CLIENT` to your test sign-up/sign-in user flow. Leave `DEMO_PROVISIONING` out of the customer flow; it uses a tenant administrative sign-in.
3. On the **DEMO_API enterprise application**, under **Single sign-on > Attributes & Claims**, add `Customer_Label` via **Directory schema extension > b2c-extensions-app**. Use an existing attribute and a test user with a populated value. If the claim is used for access control, map a separately provisioned `customer_id` that customers cannot set or edit; don't authorize on a self-entered label. See [Add attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token).

The user-flow assignment and extension attribute claim mapping are not deployed by this template.

## Use the CLI

From the repository root, run the CLI with the .NET 10 SDK. Use your tenant authority and the `clientId` and `apiScope` from the deployment output. The CLI prints the decoded access-token claims without printing the raw token.

```powershell
$cliId = Read-Host "clientId from the deployment"
$scope = Read-Host "apiScope from the deployment"
$authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/"
dotnet run --project .\EntraTokenDemo -- $cliId $authority $scope
```

For `create-user`, set `ENTRA_PROVISION_CLIENT_ID` to the `provisioningClientId` output and `ENTRA_EXTENSIONS_APP_ID` to the existing `b2c-extensions-app` application (client) ID.
