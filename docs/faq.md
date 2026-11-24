# Troubleshooting FAQ

Use this guide with the [Entra External ID lab walkthrough](../README.md). Commands and portal operations are documented there; this page covers common recovery checks.

## Deployment fails with `AuthorizationFailed`

The azd hook deploys at tenant scope. Confirm that the signed-in deployment identity has Azure RBAC permissions at `/` and is authorized to create or update the Entra applications, manage the lab group, and assign the API application role. These deployment permissions are separate from the provisioning application's delegated Graph permissions. See [deployment requirements](../infra/README.md#deploy).

The direct Azure CLI deployment does not use the azd hook. Follow the [direct deployment procedure](../infra/README.md#deploy) from the `infra` directory.

## `create-user` reports that group membership or role assignment was not confirmed

The account may already have been created. Follow the CLI's recovery message and check the lab group's **Members** and the API enterprise application's **Users and groups**. Complete only the missing assignment manually; **do not rerun `create-user`**, because that can attempt to create the account again.

For Graph HTTP 400 errors, read the reported error message to identify the rejected property. The CLI reports the HTTP status, request ID, and Graph error details; inspect the output for customer or tenant information before sharing it.

## The M2M token does not contain the lab group ID

Redeploy the current template, request a fresh token, and confirm the M2M service principal is a member of the lab security group. The API app registration must have `groupMembershipClaims` set to `SecurityGroup`. Group IDs are emitted in `groups`; the `CRM.Read.App` application role is assigned directly and appears in `roles`, not through group membership. See the [M2M token scenario](../README.md#machine-to-machine-access-token).

## The token is missing `Customer_Label` or `Reader`

Confirm that the test user has a `Customer_Label` value and that the `Customer_Label` claim is mapped on the API enterprise application. `Reader` is an API role assignment: check **Users and groups** on the API enterprise application. The token must be requested for the lab API, and a new token is needed after changing claims or assignments.

## The customer user flow is unavailable or allows sign-up

The default setup path requires a sign-in flow configured for **Email with password**, with self-service sign-up disabled and only the lab client linked. The flow is configured in the external tenant; it is not deployed by the default template. See [Finish the Entra configuration](../README.md#3-finish-the-entra-configuration).

## Can I use a customer label for authorization?

No. `Customer_Label` is demonstration data and is not a trusted authorization boundary. For real access control, use a stable, admin-managed `customer_id`, validate the token, and enforce scopes, roles, and the customer data boundary in the API.

## Does deleting the Azure deployment remove the lab?

No. Delete the lab app registrations and security group in the Entra admin center. Remove the test user and flow only if created for this lab, and remove temporary Azure RBAC access. The [cleanup procedure](../README.md#cleanup) lists the resources.
