# Entra External ID hands-on lab

Deploy three app registrations, create a test customer, then inspect the access token that the client requests for the API. Use an existing test tenant and an email address you control. The lab does not create a tenant or deploy an API server.

## 1. Set up the lab with Azure Developer CLI

Run the setup commands in PowerShell 7 from the folder containing `azure.yaml` and `infra`. The Microsoft Graph PowerShell module is needed only for the optional automated flow setup.

```powershell
# Install only the tools you are missing.
winget install --exact --id Microsoft.Azd
winget install --exact --id Microsoft.AzureCLI
winget install --exact --id Microsoft.DotNet.SDK.10

# If az or azd is still not recognized after installation, reopen PowerShell.
az bicep upgrade

# Create a local environment only if you do not already have one.
azd env new entra-lab

# Required for the selected environment.
azd env set APP_PREFIX DEMO
```

## 2. Deploy the apps and set up a sign-in-only user flow

Both setup paths use the [PowerShell hook](scripts/preprovision.ps1) to deploy the three [Bicep](infra/main.bicep) app registrations. The hook asks for the existing tenant ID if needed, verifies that Azure CLI is signed in to that tenant, and saves the app IDs and scopes to the selected azd environment. It never creates a tenant and does not require a subscription.

**Use `azd hooks run preprovision`, not `azd up` or `azd provision`.** The latter commands also run azd's built-in provisioning, which does not support this tenant-scoped Bicep template.

`APP_PREFIX` is required (1 to 38 ASCII letters or digits). `APP_SUFFIX` is optional: if unset, the hook generates and saves a random 12-character suffix before deploying. To choose your own, run `azd env set APP_SUFFIX DEV` before either path (1 to 20 ASCII letters or digits). The hook uses uppercase names. Prefix `DEMO` and suffix `DEV` give you `DEMO_PROVISIONING_DEV`, `DEMO_API_DEV`, and `DEMO_CLIENT_DEV`. Keep both settings on reruns. Changing either deploys a separate set with a distinct API scope; it does not rename or delete existing registrations.

Use an account with both Entra application management permissions and Azure Resource Manager deployment permissions at tenant scope (`/`). If deployment validation returns `AuthorizationFailed`, check your Azure RBAC role at `/`, not just your Entra directory role.

### Manual user flow setup (default)

```powershell
azd hooks run preprovision
```

By default, the hook does not sign in through Microsoft Graph PowerShell or change user flows. In the [Entra admin center](https://entra.microsoft.com), switch to the same external tenant and sign in as an **External ID User Flow Administrator** or equivalent:

1. Go to **Entra ID > External Identities > User flows > New user flow**. Give the flow a unique name, choose **Email Accounts > Email with password**, leave `Customer_Label` out of **User attributes**, and create the flow. If you already have a suitable sign-in-only flow with email and password, skip to step 3.
2. Disable self-service sign-up before linking the client. The portal does not expose this setting. Use an approved Microsoft Graph client signed in to the same tenant with admin consent to delegated `EventListener.ReadWrite.All`. No Graph PowerShell module is needed for this path. If you use [Graph Explorer](https://developer.microsoft.com/graph/graph-explorer), first consent may add its own enterprise application.

   Run `GET https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows` and copy the `id` of the flow with the exact name you created (follow `@odata.nextLink` if needed). Send `PATCH https://graph.microsoft.com/v1.0/identity/authenticationEventsFlows/<flow-id>` with `Content-Type: application/json` and the following body. Expect `204 No Content`.

   ```json
   {
     "@odata.type": "#microsoft.graph.externalUsersSelfServiceSignUpEventsFlow",
     "onInteractiveAuthFlowStart": {
       "@odata.type": "#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp",
       "isSignUpAllowed": false
     }
   }
   ```

3. In the portal, open the flow under **Use > Applications > Add application**. Add only the lab client, for example `DEMO_CLIENT_DEV`. Do not add the provisioning app to the customer flow.

### Automatic user flow setup (opt-in)

**First consent can add the Microsoft Graph Command Line Tools enterprise application to the external tenant.** It is the service principal for Microsoft's existing app registration, not a fourth lab-owned app registration. An administrator must grant consent to delegated `EventListener.ReadWrite.All`. Sign in to Graph as an **External ID User Flow Administrator** or equivalent.

Run this in PowerShell 7 from the lab root:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -ErrorAction Stop

$env:ENTRA_AUTO_CREATE_USER_FLOW = 'true'
try {
    azd hooks run preprovision
} finally {
    Remove-Item Env:\ENTRA_AUTO_CREATE_USER_FLOW -ErrorAction SilentlyContinue
}
```

The hook creates `LabSignIn-<PREFIX>-<SUFFIX>` with **Email with password** and sign-up disabled, links the client, and saves `ENTRA_USER_FLOW_ID`. It reuses a linked sign-in-only flow. It refuses to change the sign-up setting of a shared or unmanaged flow and will not link the client to an unrelated flow with the same name.

## 3. Finish the Entra configuration

After the hook succeeds, complete these steps manually in the same external tenant. Use the app names with the prefix and suffix shown by the hook:

1. Under **App registrations > API permissions**, grant admin consent for delegated `CRM.Read` on `DEMO_CLIENT` and delegated Microsoft Graph `User.ReadWrite.All` on `DEMO_PROVISIONING`.
2. Go to **Entra ID > External Identities > Overview > Custom user attributes**. Create a string attribute named `Customer_Label` if it does not exist. The CLI sets it at the tenant level; do not collect it in the user flow.
3. On the `DEMO_API` **enterprise application**, open **Single sign-on > Attributes & Claims > Add new claim**. Name the claim `Customer_Label` and map it from **Directory schema extension > b2c-extensions-app**, using the `Customer_Label` attribute as its source.

## 4. Set a customer label and inspect the token

Use the .NET 10 SDK and run the CLI from the repository root. Load these settings for either customer path:

```powershell
$lab = azd env get-values --output json | Out-String | ConvertFrom-Json
$authority = $lab.ENTRA_AUTHORITY
if (-not $authority) { $authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/" }
$env:ENTRA_PROVISION_CLIENT_ID = $lab.ENTRA_PROVISION_CLIENT_ID
$env:ENTRA_EXTENSIONS_APP_ID = (Read-Host "Application (client) ID of b2c-extensions-app").Trim()
```

### New customer

Use `create-user` with an email address you control. Sign in as the provisioning operator, then enter the customer's initial password at the hidden prompt.

```powershell
$email = Read-Host "Test customer's email address"
dotnet run --project .\EntraTokenDemo -- create-user `
  $authority $email "Jane" "Doe" "customer_label:LAB"
```

### Existing customer

Copy the user's **Object ID** from **Entra ID > Users** in the same tenant. Sign in as an operator authorized to update the user. `update-user` changes only `Customer_Label`; it does not create an account or reset the password. It accepts `customer_lab` or `customer_label` (case-insensitive) and preserves the value's case.

```powershell
$userObjectId = Read-Host "Existing customer's Object ID"
dotnet run --project .\EntraTokenDemo -- update-user `
  $authority $userObjectId "customer_lab:LAB"
```

### Assign the Reader role and inspect the access token

On the API **enterprise application** (for example, `DEMO_API_DEV`), go to **Users and groups > Add user/group**. Select the test customer, choose **Reader** under **Select a role**, and choose **Assign**. The template defines the role; it does not assign it.

Sign in as the **test customer**, not the provisioning operator:

```powershell
dotnet run --project .\EntraTokenDemo -- `
  $lab.ENTRA_CLIENT_ID $authority $lab.ENTRA_API_SCOPE
```

Look for `aud` matching `ENTRA_API_APP_ID`, `scp` containing `CRM.Read`, `roles` containing `Reader` after assignment, and `Customer_Label` set to `LAB`. Try again with `ENTRA_API_DEFAULT_SCOPE` in place of `ENTRA_API_SCOPE`: it still targets the same API. Bare `.default` does not. The CLI decodes the payload by default; it does not validate it.

Example decoded payload (selected claims; identifiers redacted and label synthetic):

```json
{
  "aud": "<api-app-client-id>",
  "iss": "https://<tenant>.ciamlogin.com/<tenant-id>/v2.0",
  "tid": "<tenant-id>",
  "oid": "<user-object-id>",
  "scp": "CRM.Read",
  "roles": ["Reader"],
  "Customer_Label": "LAB",
  "ver": "2.0"
}
```

Add `--raw` after the scope only when you need the bearer token locally. Treat it like a password; do not share it or paste it into logs.

For real access control, use a stable, admin-managed `customer_id` rather than a user-entered label. Validate the access token and enforce the required scopes, roles, and customer data boundary in the API.

## 5. Clean up

Delete the three lab app registrations in the Entra admin center. Delete the test customer and flow only if you created them for the lab; for existing resources, undo any lab-specific assignment or label changes instead. Deleting the ARM deployment record does not delete Entra objects. Remove any temporary Azure RBAC assignment or elevated access used for deployment.

*This lab guide was drafted with AI assistance.*

## Learn more

- [Azure Developer CLI environments](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/work-with-environments)
- [Run Azure Developer CLI hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
- [Deploy Microsoft Graph Bicep without an Azure subscription](https://learn.microsoft.com/en-us/graph/templates/bicep/how-to-deploy-without-azure-sub)
- [Microsoft Entra scopes and `.default`](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope)
- [Disable self-service sign-up in an External ID user flow](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-disable-sign-up-user-flow)
- [Add External ID attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token)
- [Validate access-token claims in your API](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation)
