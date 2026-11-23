# Entra External ID hands-on lab

Deploy the lab app registrations and inspect an API access token from a test customer or a machine-to-machine (M2M) client. Use an existing test tenant and an email address you control. The lab does not create a tenant or deploy an API server.

## 1. Set up the lab with Azure Developer CLI

Run the setup commands in PowerShell 7 from the repository root. Use an account with Entra app management permissions and Azure RBAC permissions at tenant scope (`/`).

```powershell
# Install only the tools you are missing.
winget install --exact --id Microsoft.Azd
winget install --exact --id Microsoft.AzureCLI
winget install --exact --id Microsoft.DotNet.SDK.10

# If az or azd is still not recognized after installation, reopen PowerShell.
az bicep upgrade

# Create a local environment only if you do not already have one.
azd env new entra-lab
```

## 2. Deploy the apps and set up a sign-in-only user flow

Expand one path below and enter `DEMO` if the hook prompts for a prefix.

<a name="manual-user-flow-setup-default"></a>

<details>
<summary>Manual user flow setup (default)</summary>

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

</details>

<a name="automatic-user-flow-setup-opt-in"></a>

<details>
<summary>Automatic user flow setup (opt-in)</summary>

**First consent can add the Microsoft Graph Command Line Tools enterprise application to the external tenant.** It is the service principal for Microsoft's existing app registration, not a lab-owned app registration. An administrator must grant consent to delegated `EventListener.ReadWrite.All`. Sign in to Graph as an **External ID User Flow Administrator** or equivalent.

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

</details>

## 3. Finish the Entra configuration

After the hook succeeds, complete these steps manually in the same external tenant. Use the app names with the prefix and suffix shown by the hook:

1. Under **App registrations > API permissions**, review and grant admin consent separately for each app: `CRM.Read` on `DEMO_CLIENT`; Microsoft Graph `User.ReadWrite.All`, `Application.Read.All`, and `AppRoleAssignment.ReadWrite.All` on `DEMO_PROVISIONING`. Bicep declares these delegated permissions but does not grant consent.
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
$env:ENTRA_API_APP_ID = $lab.ENTRA_API_APP_ID
```

Expand one customer path:

<details>
<summary>New customer: create an account by email</summary>

`create-user` assigns `Reader` by default. Use an operator authorized to create users and assign API roles after granting consent in step 3.

Use an email address you control and enter the initial password at the hidden prompt:

```powershell
$email = Read-Host "Test customer's email address"
dotnet run --project .\EntraTokenDemo -- create-user `
  $authority $email "Jane" "Doe" "customer_label:LAB" --role Reader
```

The label is positional. Use `--role <value>` to select another enabled user role by its case-sensitive value, or `--no-role` to skip assignment. With `--no-role`, the CLI requests only `User.ReadWrite.All` and does not need the API client ID. If creation succeeds but assignment fails, assign the role manually; do not rerun `create-user`.

</details>

<details>
<summary>Existing customer: set the label by Object ID</summary>

Copy the user's **Object ID** from **Entra ID > Users** in the same tenant. Sign in as an operator authorized to update the user. `update-user` changes only `Customer_Label`; it does not create an account or reset the password. It accepts `customer_lab` or `customer_label` (case-insensitive) and preserves the value's case.

```powershell
$userObjectId = Read-Host "Existing customer's Object ID"
dotnet run --project .\EntraTokenDemo -- update-user `
  $authority $userObjectId "customer_lab:LAB"
```

</details>

### Inspect the access token

To assign `Reader` manually, open the API **enterprise application** and choose **Users and groups > Add user/group**. Select the customer and the `Reader` role, then choose **Assign**.

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

Delete the four lab app registrations in the Entra admin center. If you ran the M2M claims experiment, also remove its two isolated registrations and the policy identified by `ENTRA_M2M_CLAIMS_POLICY_ID`. Delete the test customer and flow only if you created them for the lab; for existing resources, undo any lab-specific assignment or label changes instead. Deleting the ARM deployment record does not delete Entra objects. Remove any temporary Azure RBAC assignment or elevated access used for deployment.

## Machine-to-machine access token

On the `<PREFIX>_M2M_<SUFFIX>` app registration, grant admin consent for the API's `CRM.Read.App` application permission, then create a short-lived secret under **Certificates & secrets**. The hook saves the app ID, never the secret. [External ID bills M2M authentication per transaction](https://learn.microsoft.com/en-us/entra/external-id/external-identities-pricing).

```powershell
$lab = azd env get-values --output json | Out-String | ConvertFrom-Json
$authority = $lab.ENTRA_AUTHORITY
if (-not $authority) { $authority = Read-Host 'External tenant authority URL' }
$env:ENTRA_M2M_CLIENT_ID = $lab.ENTRA_M2M_CLIENT_ID
$env:ENTRA_M2M_CLIENT_SECRET = Read-Host 'M2M client secret value' -MaskInput
try {
    dotnet run --project .\EntraTokenDemo -- client-credentials $authority $lab.ENTRA_API_DEFAULT_SCOPE
} finally {
    Remove-Item Env:\ENTRA_M2M_CLIENT_SECRET -ErrorAction SilentlyContinue
}
```

Look for `aud` matching `ENTRA_API_APP_ID` and `roles` containing `CRM.Read.App`. An app-only access token uses an application role (`roles`), not a delegated scope (`scp`). This path does not use the customer user flow.

## M2M claims mapping (Work In Progress)

**Live app-only issuance of `m2m_customer_tag` is unverified.** This opt-in experiment uses a separate single-tenant API and confidential client. It tests whether a policy can map the client service principal's synthetic `customer:LAB-A` tag into the app-only token. Entra may omit the claim or emit a different value. Do not use the tag for authorization.

Run in an existing test tenant. The Microsoft Graph PowerShell sign-in requires admin consent for delegated `Policy.Read.All`, `Policy.ReadWrite.ApplicationConfiguration`, and `Application.ReadWrite.All`. First consent can add the **Microsoft Graph Command Line Tools** enterprise application. Sign in as an operator authorized to manage applications and claims-mapping policies.

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -ErrorAction Stop
$env:ENTRA_ENABLE_M2M_CLAIMS_LAB = 'true'
try {
    azd hooks run preprovision
} finally {
    Remove-Item Env:\ENTRA_ENABLE_M2M_CLAIMS_LAB -ErrorAction SilentlyContinue
}
```

Grant `CRM.Read.App` admin consent and create a short-lived secret for `<PREFIX>_CLAIMS_M2M_<SUFFIX>` in the portal. Rerun the normal M2M commands above with `ENTRA_M2M_CLAIMS_CLIENT_ID`, that client's secret value, and `ENTRA_M2M_CLAIMS_API_DEFAULT_SCOPE` in place of the regular app ID, secret, and scope. Neither template creates a secret or grants consent. The hook attaches the policy only to the isolated API and leaves the main API's `Customer_Label` mapping unchanged.

*This lab guide was drafted with AI assistance.*

## Learn more

- [Infrastructure reference and naming options](infra/README.md)
- [Azure Developer CLI environments](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/work-with-environments)
- [Run Azure Developer CLI hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
- [Deploy Microsoft Graph Bicep without an Azure subscription](https://learn.microsoft.com/en-us/graph/templates/bicep/how-to-deploy-without-azure-sub)
- [Microsoft Entra scopes and `.default`](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope)
- [Disable self-service sign-up in an External ID user flow](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-disable-sign-up-user-flow)
- [Add External ID attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token)
- [Validate access-token claims in your API](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation)
