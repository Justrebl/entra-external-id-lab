# Entra External ID app registrations

The tenant-scoped template creates three single-tenant app registrations and their enterprise applications in an **existing** tenant. It cannot create a tenant, creates no secrets, and does not grant consent.

| Registration | Configuration |
| --- | --- |
| `DEMO_PROVISIONING` | Desktop loopback `http://localhost`; requests delegated Microsoft Graph `User.ReadWrite.All` for `create-user` and `update-user`. |
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

The azd hook requires `APP_PREFIX` and generates and saves a random `APP_SUFFIX` if none is configured. The direct Azure CLI command above defaults to `DEMO` with unsuffixed names. To set them explicitly, pass `--parameters namePrefix=DEMO appSuffix=DEV` and use a distinct deployment name (for example, `entra-lab-apps-dev`). Match the hook's uppercase prefix and suffix when using either method to redeploy the same apps. Keep them stable: they determine the app names, `uniqueName` values, API identifier URI, and the deterministic `Reader` role ID. The template identifies registrations by `uniqueName`, not display name; it does not automatically adopt apps created in the portal.

## Finish the tenant setup

Use the suffixed app names below if you set a suffix.

1. In **App registrations > API permissions**, review and grant admin consent separately for `DEMO_CLIENT` (`CRM.Read`) and `DEMO_PROVISIONING` (`User.ReadWrite.All`). Keep this provisioning permission off the customer-facing client and sign in to the provisioning CLI only as an authorized operator.
2. Follow the [manual user flow setup](../README.md#manual-user-flow-setup-default): set up an **Email with password** flow, disable sign-up, and link only `DEMO_CLIENT`. Leave `DEMO_PROVISIONING` out of the customer flow; it uses a tenant administrative sign-in. The azd hook configures the flow only when you opt in.
3. On the **DEMO_API enterprise application**, under **Single sign-on > Attributes & Claims**, add `Customer_Label` via **Directory schema extension > b2c-extensions-app**. Use an existing attribute and a test user with a populated value. If the claim is used for access control, map a separately provisioned `customer_id` that customers cannot set or edit; don't authorize on a self-entered label. See [Add attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token).

The flow, extension claim mapping, and role assignment are not deployed by this template. Assign the test customer to `Reader` under **Users and groups** on the API enterprise application, then request a fresh access token to see `roles: ["Reader"]`.

## Use the CLI

From the repository root, run the CLI with the .NET 10 SDK. Use your tenant authority and the `clientId` and `apiScope` from the deployment output. The CLI prints the decoded access-token claims without printing the raw token.

```powershell
$cliId = Read-Host "clientId from the deployment"
$scope = Read-Host "apiScope from the deployment"
$authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/"
dotnet run --project .\EntraTokenDemo -- $cliId $authority $scope
```

For `create-user` and `update-user`, set `ENTRA_PROVISION_CLIENT_ID` to the `provisioningClientId` output and `ENTRA_EXTENSIONS_APP_ID` to the existing `b2c-extensions-app` application (client) ID. See the [CLI walkthrough](../README.md#4-set-a-customer-label-and-inspect-the-token) for command examples.
