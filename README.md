# Entra External ID hands-on lab

Deploy three app registrations, create a test customer, then inspect the access token that the client requests for the API. Use an existing test tenant and an email address you control. The lab does not create a tenant or deploy an API server.

## 1. Set up the lab with Azure Developer CLI

Run the setup commands in PowerShell 7 from the folder containing `azure.yaml` and `infra`:

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

## 2. Deploy the app registrations

From the lab root, run this command with your azd environment selected:

```powershell
# Optional: uncomment to choose a suffix instead of generating one.
# azd env set APP_SUFFIX DEV
azd hooks run preprovision
```

**Use this command instead of `azd up` or `azd provision`.** It runs the [PowerShell hook](scripts/preprovision.ps1) for you. The other commands also invoke azd's built-in provisioning, which does not support this tenant-scoped Bicep template.

The hook asks for the existing tenant ID if needed, verifies that Azure CLI is signed in to that tenant, deploys the three app registrations with [Bicep](infra/main.bicep), and saves their IDs and scopes in the selected azd environment. It never creates a tenant and does not require a subscription.

If `APP_SUFFIX` is unset, the hook generates a random 12-character suffix and saves it in the selected azd environment before deploying. Reruns reuse it, even if the first deployment failed. To choose your own, use 1 to 20 ASCII letters or digits. `DEV` gives you `DEMO_PROVISIONING_DEV`, `DEMO_API_DEV`, and `DEMO_CLIENT_DEV`, with a distinct API scope. Changing the suffix deploys a separate set; it does not rename or delete existing registrations.

Use an account with both Entra application management permissions and Azure Resource Manager deployment permissions at tenant scope (`/`). If deployment validation returns `AuthorizationFailed`, check your Azure RBAC role at `/`, not just your Entra directory role.

## 3. Finish the Entra configuration

After the hook succeeds, complete these steps manually in the Entra admin center. Use the app names ending in the `APP_SUFFIX` shown by the hook:

1. Under **App registrations > API permissions**, grant admin consent for delegated `CRM.Read` on `DEMO_CLIENT_<suffix>` and delegated Microsoft Graph `User.ReadWrite.All` on `DEMO_PROVISIONING_<suffix>`.
2. Add `DEMO_CLIENT_<suffix>` to your sign-up/sign-in user flow and enable **Email with password** for this lab. Do not add the provisioning app to the customer flow.
3. Create a string custom user attribute named `Customer_Label` if it does not exist. On the `DEMO_API_<suffix>` **enterprise application**, open **Single sign-on > Attributes & Claims** and map `Customer_Label` from **Directory schema extension > b2c-extensions-app**. The provisioning CLI sets the value, so you do not need to collect it at sign-up.

## 4. Create a customer and inspect the token

Use the .NET 10 SDK to run the CLI from source:

```powershell
$lab = azd env get-values --output json | Out-String | ConvertFrom-Json
$authority = $lab.ENTRA_AUTHORITY
if (-not $authority) { $authority = Read-Host "Authority URL, e.g. https://example.ciamlogin.com/" }
$env:ENTRA_PROVISION_CLIENT_ID = $lab.ENTRA_PROVISION_CLIENT_ID
$env:ENTRA_EXTENSIONS_APP_ID = (Read-Host "Application (client) ID of b2c-extensions-app").Trim()
$email = Read-Host "Test customer's email address"
dotnet run --project .\EntraTokenDemo -- create-user `
  $authority $email "Jane" "Doe" "customer_label:LAB"
```

Sign in as the provisioning operator, then enter the customer's initial password at the hidden prompt. For the next command, sign in as the **test customer**, not the operator:

```powershell
dotnet run --project .\EntraTokenDemo -- `
  $lab.ENTRA_CLIENT_ID $authority $lab.ENTRA_API_SCOPE
```

Look for `aud` matching `ENTRA_API_APP_ID`, `scp` containing `CRM.Read`, and `Customer_Label` set to `LAB`. Try again with `ENTRA_API_DEFAULT_SCOPE` in place of `ENTRA_API_SCOPE`: it still targets the same API. Bare `.default` does not. The CLI decodes the payload; it does not validate it. Only use `--raw` if you need the bearer token locally, and do not share it.

For real access control, use a stable, admin-managed `customer_id` rather than a user-entered label. Validate the access token and scope in the API and enforce the customer's data boundary in every query.

## 5. Clean up

Delete the lab customer and the three lab registrations in the Entra admin center when you are done. Deleting the ARM deployment record does not delete the Entra objects. Remove any temporary Azure RBAC assignment or elevated access used for deployment.

*This lab guide was drafted with AI assistance.*

## Learn more

- [Azure Developer CLI environments](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/work-with-environments)
- [Run Azure Developer CLI hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
- [Deploy Microsoft Graph Bicep without an Azure subscription](https://learn.microsoft.com/en-us/graph/templates/bicep/how-to-deploy-without-azure-sub)
- [Microsoft Entra scopes and `.default`](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope)
- [Add External ID attributes to token claims](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-add-attributes-to-token)
- [Validate access-token claims in your API](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation)
