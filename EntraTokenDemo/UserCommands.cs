using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Mail;
using System.Text;
using System.Text.Json;
using Microsoft.Identity.Client;

internal static class UserCommands
{
    private const string AttributeName = "Customer_Label";
    private const string AuthoritySuffix = ".ciamlogin.com";
    private const string GraphUsersUrl = "https://graph.microsoft.com/v1.0/users";
    private const string GraphServicePrincipalsUrl = "https://graph.microsoft.com/v1.0/servicePrincipals";
    private const string GraphScopePrefix = "https://graph.microsoft.com/";
    private const string DefaultRole = "Reader";

    public static void PrintUsage()
    {
        Console.Error.WriteLine("       dotnet run -- create-user <https-authority> <email> <given-name> <surname> \"customer_label:<value>\" [--role <value> | --no-role] (default: Reader)");
        Console.Error.WriteLine("       dotnet run -- update-user <https-authority> <user-object-id> \"customer_lab:<value>\" (also accepts customer_label)");
    }

    public static async Task<int> RunAsync(string[] args, bool update)
    {
        var requiredCount = update ? 3 : 5;
        if (args.Length < requiredCount)
        {
            PrintUsage();
            return 2;
        }
        string? role = (update, args[requiredCount..]) switch
        {
            (true, []) => null,
            (false, []) => DefaultRole,
            (false, ["--no-role"]) => null,
            (false, ["--role", var value]) when !string.IsNullOrWhiteSpace(value) && !value.StartsWith("--", StringComparison.Ordinal) => value,
            _ => ""
        };
        if (role == "")
        {
            PrintUsage();
            return 2;
        }

        if (!Uri.TryCreate(args[0], UriKind.Absolute, out var authority) ||
            authority.Scheme != Uri.UriSchemeHttps || !authority.IsDefaultPort ||
            authority.AbsolutePath != "/" || authority.Query.Length != 0 ||
            authority.Fragment.Length != 0 || authority.UserInfo.Length != 0 ||
            !authority.Host.EndsWith(AuthoritySuffix, StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Use your external tenant root URL: https://<tenant>.ciamlogin.com/.");
            return 2;
        }

        var tenant = authority.Host[..^AuthoritySuffix.Length];
        if (tenant.Length == 0 || tenant.Contains('.'))
        {
            Console.Error.WriteLine("Use your external tenant root URL: https://<tenant>.ciamlogin.com/.");
            return 2;
        }

        var userId = Guid.Empty;
        var email = "";
        var givenName = "";
        var surname = "";
        if (update)
        {
            if (!Guid.TryParse(args[1], out userId) || userId == Guid.Empty)
            {
                Console.Error.WriteLine("Provide the existing user's Entra Object ID (a non-empty GUID).");
                return 2;
            }
        }
        else
        {
            email = args[1].Trim();
            givenName = args[2].Trim();
            surname = args[3].Trim();
            if (!MailAddress.TryCreate(email, out var address) || address.Address != email ||
                givenName.Length == 0 || surname.Length == 0)
            {
                Console.Error.WriteLine("Provide a plain email address, a given name, and a surname.");
                return 2;
            }
        }

        var attribute = args[requiredCount - 1];
        var separator = attribute.IndexOf(':');
        var labelKey = separator < 0 ? "" : attribute[..separator].Trim();
        var label = separator < 0 ? "" : attribute[(separator + 1)..].Trim();
        if (label.Length == 0 ||
            !(labelKey.Equals(AttributeName, StringComparison.OrdinalIgnoreCase) ||
              (update && labelKey.Equals("customer_lab", StringComparison.OrdinalIgnoreCase))))
        {
            var syntax = update ? "customer_lab:<value> or customer_label:<value>" : "customer_label:<value>";
            Console.Error.WriteLine($"Provide {syntax} with a non-empty value.");
            return 2;
        }

        if (!Guid.TryParse(Environment.GetEnvironmentVariable("ENTRA_PROVISION_CLIENT_ID"), out var clientId) ||
            clientId == Guid.Empty)
        {
            Console.Error.WriteLine("Set ENTRA_PROVISION_CLIENT_ID to the provisioning app's Application (client) ID.");
            return 2;
        }
        if (!Guid.TryParse(Environment.GetEnvironmentVariable("ENTRA_EXTENSIONS_APP_ID"), out var extensionsId) ||
            extensionsId == Guid.Empty)
        {
            Console.Error.WriteLine("Set ENTRA_EXTENSIONS_APP_ID to the b2c-extensions-app Application (client) ID.");
            return 2;
        }
        var apiAppId = Guid.Empty;
        if (role is not null &&
            (!Guid.TryParse(Environment.GetEnvironmentVariable("ENTRA_API_APP_ID"), out apiAppId) || apiAppId == Guid.Empty))
        {
            Console.Error.WriteLine("Set ENTRA_API_APP_ID to the API's Application (client) ID, or use --no-role.");
            return 2;
        }
        if (!update && Console.IsInputRedirected)
        {
            Console.Error.WriteLine("Run create-user in an interactive terminal for the masked password prompt.");
            return 2;
        }

        var tenantDomain = $"{tenant}.onmicrosoft.com";
        var operation = update ? "update" : "create";
        var retryHint = role is null
            ? (update ? "Check the user's label before retrying." : "Check whether the account exists before retrying.")
            : "No account was created; the API role must be verified first.";
        const string assignmentRecovery = "Customer account created, but the role assignment was not confirmed. Check Users and groups on the API enterprise application and assign the role there if needed. Do not rerun create-user.";
        string[] scopes = role is null
            ? ["User.ReadWrite.All"]
            : ["User.ReadWrite.All", "Application.Read.All", "AppRoleAssignment.ReadWrite.All"];
        try
        {
            Console.Error.WriteLine($"Sign in to {tenantDomain} with an account authorized to {operation} users.");
            var result = await PublicClientApplicationBuilder.Create(clientId.ToString())
                .WithAuthority($"https://login.microsoftonline.com/{tenantDomain}")
                .WithRedirectUri("http://localhost")
                .Build()
                .AcquireTokenInteractive(scopes.Select(scope => GraphScopePrefix + scope))
                .WithUseEmbeddedWebView(false)
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync();

            if (role is not null && scopes.Any(scope => !result.Scopes.Any(granted =>
                granted.Equals(scope, StringComparison.OrdinalIgnoreCase) ||
                granted.Equals(GraphScopePrefix + scope, StringComparison.OrdinalIgnoreCase))))
            {
                Console.Error.WriteLine("The Graph token lacks a required delegated permission for role assignment. No account was created.");
                return 1;
            }

            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            {
                Timeout = TimeSpan.FromSeconds(30)
            };
            http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", result.AccessToken);
            var assignment = role is null ? null : await ResolveUserRoleAsync(http, apiAppId, role);
            if (role is not null && assignment is null)
            {
                Console.Error.WriteLine("No account was created. Check the API app ID, role value, and operator permissions, or use --no-role.");
                return 1;
            }

            if (assignment is not null)
            {
                retryHint = "Check whether the account exists before retrying.";
            }
            var extensionProperty = $"extension_{extensionsId:N}_{AttributeName}";
            using var response = update
                ? await http.PatchAsJsonAsync($"{GraphUsersUrl}/{userId:D}", new Dictionary<string, string> { [extensionProperty] = label })
                : await CreateUserAsync(http, tenantDomain, email, givenName, surname, extensionProperty, label);
            if (response is null)
            {
                return 2;
            }
            if (response.StatusCode != (update ? HttpStatusCode.NoContent : HttpStatusCode.Created))
            {
                ReportGraphStatus($"Graph did not report {(update ? "an update" : "creation")}", response);
                return 1;
            }

            if (assignment is not null)
            {
                retryHint = assignmentRecovery;
                var createdUser = await response.Content.ReadFromJsonAsync<CreatedUser>();
                if (createdUser is null || createdUser.Id == Guid.Empty)
                {
                    Console.Error.WriteLine($"Graph did not return the new user's object ID. {assignmentRecovery}");
                    return 1;
                }

                using var roleResponse = await AssignUserRoleAsync(http, assignment, createdUser.Id);
                if (roleResponse.StatusCode != HttpStatusCode.Created)
                {
                    ReportGraphStatus("Graph did not confirm role assignment", roleResponse);
                    Console.Error.WriteLine(assignmentRecovery);
                    return 1;
                }
            }

            Console.WriteLine(update ? "Customer label updated." : role is null
                ? "Customer account created."
                : $"Customer account created and assigned the {role} API role.");
            return 0;
        }
        catch (MsalException ex)
        {
            Console.Error.WriteLine($"Admin sign-in failed: {ex.ErrorCode} (correlation ID: {ex.CorrelationId}).");
            return 1;
        }
        catch (HttpRequestException ex)
        {
            Console.Error.WriteLine($"Graph request failed: {ex.HttpRequestError}. {retryHint}");
            return 1;
        }
        catch (JsonException)
        {
            Console.Error.WriteLine($"Microsoft Graph returned an unexpected response. {retryHint}");
            return 1;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine($"Request canceled or timed out. {retryHint}");
            return 1;
        }
    }

    private sealed record GraphRole(Guid Id, string? Value, bool IsEnabled, string[]? AllowedMemberTypes);
    private sealed record GraphPrincipal(Guid Id, Guid AppId, GraphRole[]? AppRoles);
    private sealed record CreatedUser(Guid Id);
    private sealed record RoleAssignment(Guid ResourceId, Guid RoleId);

    private static async Task<RoleAssignment?> ResolveUserRoleAsync(HttpClient http, Guid apiAppId, string role)
    {
        using var response = await http.GetAsync($"{GraphServicePrincipalsUrl}(appId='{apiAppId:D}')?$select=id,appId,appRoles");
        if (response.StatusCode != HttpStatusCode.OK)
        {
            ReportGraphStatus("Graph could not read the API enterprise application", response);
            return null;
        }

        var principal = await response.Content.ReadFromJsonAsync<GraphPrincipal>();
        if (principal is null || principal.Id == Guid.Empty || principal.AppId != apiAppId || principal.AppRoles is null)
        {
            Console.Error.WriteLine("Graph did not return the expected API enterprise application and its roles.");
            return null;
        }

        var matchingRoles = principal.AppRoles.Where(candidate =>
            string.Equals(candidate.Value, role, StringComparison.Ordinal) &&
            candidate.IsEnabled && candidate.Id != Guid.Empty &&
            candidate.AllowedMemberTypes?.Contains("User", StringComparer.Ordinal) == true).ToArray();
        if (matchingRoles.Length != 1)
        {
            Console.Error.WriteLine("Expected exactly one enabled API app role with the requested case-sensitive value assignable to users.");
            return null;
        }

        return new RoleAssignment(principal.Id, matchingRoles[0].Id);
    }

    private static Task<HttpResponseMessage> AssignUserRoleAsync(HttpClient http, RoleAssignment role, Guid userId) =>
        http.PostAsJsonAsync($"{GraphServicePrincipalsUrl}/{role.ResourceId:D}/appRoleAssignedTo",
            new { principalId = userId, resourceId = role.ResourceId, appRoleId = role.RoleId });

    private static void ReportGraphStatus(string message, HttpResponseMessage response)
    {
        var requestId = response.Headers.TryGetValues("request-id", out var values) ? values.FirstOrDefault() : null;
        Console.Error.WriteLine($"{message}: HTTP {(int)response.StatusCode} (request ID: {requestId ?? "unavailable"}).");
    }

    private static async Task<HttpResponseMessage?> CreateUserAsync(
        HttpClient http, string tenantDomain, string email, string givenName, string surname, string extensionProperty, string label)
    {
        var password = ReadPassword();
        if (string.IsNullOrWhiteSpace(password))
        {
            Console.Error.WriteLine("No password entered; no account was created.");
            return null;
        }

        var user = new Dictionary<string, object>
        {
            ["accountEnabled"] = true,
            ["displayName"] = $"{givenName} {surname}",
            ["givenName"] = givenName,
            ["surname"] = surname,
            ["mail"] = email,
            ["identities"] = new[] { new { signInType = "emailAddress", issuer = tenantDomain, issuerAssignedId = email } },
            ["passwordProfile"] = new { password, forceChangePasswordNextSignIn = true },
            ["passwordPolicies"] = "DisablePasswordExpiration",
            [extensionProperty] = label
        };

        return await http.PostAsJsonAsync(GraphUsersUrl, user);
    }

    private static string ReadPassword()
    {
        Console.Error.Write("Initial password for the new customer (hidden): ");
        var password = new StringBuilder();
        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Enter)
            {
                Console.Error.WriteLine();
                return password.ToString();
            }
            if (key.Key == ConsoleKey.Backspace && password.Length > 0)
            {
                password.Length--;
            }
            else if (!char.IsControl(key.KeyChar))
            {
                password.Append(key.KeyChar);
            }
        }
    }
}
