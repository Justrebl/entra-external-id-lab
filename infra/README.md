# Entra External ID app registrations

The tenant-scoped template creates four single-tenant app registrations, their enterprise applications, and an assigned-membership security group in an **existing** tenant. It cannot create a tenant, creates no secrets, and does not grant delegated consent.

| Registration | Configuration |
| --- | --- |
| `DEMO_PROVISIONING` | Desktop loopback `http://localhost`; declares delegated Microsoft Graph `User.ReadWrite.All` for customer management, `GroupMember.ReadWrite.All` for group membership, and `Application.Read.All` and `AppRoleAssignment.ReadWrite.All` for role assignment. |
| `DEMO_API` | Exposes delegated `CRM.Read`, the `Reader` user role, and the `CRM.Read.App` application role; issues v2 access tokens and accepts mapped claims. |
| `DEMO_CLIENT` | Desktop loopback `http://localhost`; requests delegated `CRM.Read` from `DEMO_API`. |
| `DEMO_M2M` | Confidential client; its service principal receives `CRM.Read.App` directly on the `DEMO_API` service principal. |

## Deploy

For the azd workflow, see the [lab guide](../README.md). To deploy directly, run these commands from `infra` using Azure CLI and Bicep 0.36.1 or later. The deploying identity needs permission to create or update Entra applications and service principals and run ARM deployments at tenant scope (`/`). See [tenant deployment without an Azure subscription](https://learn.microsoft.com/en-us/graph/templates/bicep/how-to-deploy-without-azure-sub) and [Graph deployment permissions](https://learn.microsoft.com/en-us/graph/templates/bicep/concept-permissions-and-privileges).

The deployment also needs Microsoft Graph permissions to [manage the security group](https://learn.microsoft.com/en-us/graph/templates/bicep/reference/groups?view=graph-bicep-1.0) (`Group.ReadWrite.All`), [add its M2M service principal member](https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0) (`GroupMember.ReadWrite.All` or `Group.ReadWrite.All`, plus `Application.ReadWrite.All`), and grant the [API application role](https://learn.microsoft.com/en-us/graph/templates/bicep/reference/approleassignedto?view=graph-bicep-1.0) (`AppRoleAssignment.ReadWrite.All` and `Application.Read.All`). For an interactive Azure CLI deployment, the signed-in operator must be authorized for these actions in the target tenant. These are deployment permissions, separate from the provisioning app's delegated permissions.

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

The direct Azure CLI command defaults to `DEMO` with unsuffixed names. To reuse hook-created resources, pass matching uppercase values, for example `--parameters namePrefix=DEMO appSuffix=DEV`. Keep both values stable: they determine the names, API identifier URI, and app role IDs. Bicep identifies registrations and the security group by `uniqueName`, not display name. The group is named `<PREFIX>-Customers-<SUFFIX>` and its `customerGroupObjectId` output is saved by the hook as `ENTRA_CUSTOMER_GROUP_ID`.

## Finish the tenant setup

Use the suffixed app names below if you set a suffix.

1. In **App registrations > API permissions**, review and grant admin consent separately on `DEMO_CLIENT` and `DEMO_PROVISIONING` for the delegated permissions listed above. The template declares but does not grant them. Keep Microsoft Graph provisioning permissions off the customer-facing client and use the provisioning CLI only as an authorized operator.
2. Follow the [manual user flow setup](../README.md#manual-user-flow-setup-default): set up an **Email with password** flow, disable sign-up, and link only `DEMO_CLIENT`. Leave `DEMO_PROVISIONING` out of the customer flow; it uses a tenant administrative sign-in. The azd hook configures the flow only when you opt in.
3. On the **DEMO_API enterprise application**, under **Single sign-on > Attributes & Claims**, add `Customer_Label` via **Directory schema extension > b2c-extensions-app**. Use an existing attribute and a test user with a populated value. If the claim is used for access control, map a separately provisioned `customer_id` that customers cannot set or edit; don't authorize on a self-entered label. See [Add attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token).

The template does not deploy the flow, claim mapping, or customer role assignments. `create-user` adds the customer directly to the lab security group and assigns `Reader` by default; for existing customers, assign `Reader` under **Users and groups** on the API enterprise application.

The API app registration sets `groupMembershipClaims` to `SecurityGroup`, so access tokens include security group object IDs in `groups`. This applies to the API's access tokens, not only M2M tokens. For [machine-to-machine access](../README.md#machine-to-machine-access-token), create the standard M2M client's secret in the portal. The template appends the M2M service principal to the lab group without removing existing members. It grants the M2M role directly, not through the group. The [opt-in claims experiment](../README.md#m2m-claims-mapping-experiment-opt-in-work-in-progress) uses [a separate template](m2m-claims.bicep) and app pair; it is not part of the default deployment.

## Use the CLI

From the repository root, run the CLI with the .NET 10 SDK. Use your tenant authority and the `clientId` and `apiScope` from the deployment output. The CLI prints the decoded access-token claims without printing the raw token.

```powershell
$cliId = Read-Host "clientId from the deployment"
$scope = Read-Host "apiScope from the deployment"
$authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/"
dotnet run --project .\EntraTokenDemo -- $cliId $authority $scope
```

For `create-user` and `update-user`, set `ENTRA_PROVISION_CLIENT_ID` to the `provisioningClientId` output and `ENTRA_EXTENSIONS_APP_ID` to the existing `b2c-extensions-app` application (client) ID. For `create-user`, set `ENTRA_CUSTOMER_GROUP_ID` to `customerGroupObjectId`, and set `ENTRA_API_APP_ID` to `apiClientId` unless using `--no-role`. `create-user --no-role` still requests `User.ReadWrite.All` and `GroupMember.ReadWrite.All`; `update-user` requests only `User.ReadWrite.All` and does not use the group. See the [CLI walkthrough](../README.md#set-a-customer-label-and-inspect-the-token).

## Validate locally

From the repository root, run `pwsh -NoProfile -File .\tests\preprovision.Tests.ps1` to compile the template and check the group, role assignment, and hook outputs without signing in or deploying. The hook runs against mocked Azure CLI and azd commands.
