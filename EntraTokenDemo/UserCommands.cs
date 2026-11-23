using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Mail;
using System.Text;
using Microsoft.Identity.Client;

internal static class UserCommands
{
    private const string AttributeName = "Customer_Label";
    private const string AuthoritySuffix = ".ciamlogin.com";
    private const string GraphUsersUrl = "https://graph.microsoft.com/v1.0/users";

    public static void PrintUsage()
    {
        Console.Error.WriteLine("       dotnet run -- create-user <https-authority> <email> <given-name> <surname> \"customer_label:<value>\"");
        Console.Error.WriteLine("       dotnet run -- update-user <https-authority> <user-object-id> \"customer_lab:<value>\" (also accepts customer_label)");
    }

    public static async Task<int> RunAsync(string[] args, bool update)
    {
        if (args.Length != (update ? 3 : 5))
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

        var attribute = args[^1];
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
        if (!update && Console.IsInputRedirected)
        {
            Console.Error.WriteLine("Run create-user in an interactive terminal for the masked password prompt.");
            return 2;
        }

        var tenantDomain = $"{tenant}.onmicrosoft.com";
        var operation = update ? "update" : "create";
        var retryHint = update ? "Check the user's label before retrying." : "Check whether the account exists before retrying.";
        try
        {
            Console.Error.WriteLine($"Sign in to {tenantDomain} with an account authorized to {operation} users.");
            var result = await PublicClientApplicationBuilder.Create(clientId.ToString())
                .WithAuthority($"https://login.microsoftonline.com/{tenantDomain}")
                .WithRedirectUri("http://localhost")
                .Build()
                .AcquireTokenInteractive(["https://graph.microsoft.com/User.ReadWrite.All"])
                .WithUseEmbeddedWebView(false)
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync();

            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            {
                Timeout = TimeSpan.FromSeconds(30)
            };
            http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", result.AccessToken);
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
                var requestId = response.Headers.TryGetValues("request-id", out var values)
                    ? values.FirstOrDefault() : null;
                Console.Error.WriteLine($"Graph did not report {(update ? "an update" : "creation")}: HTTP {(int)response.StatusCode} (request ID: {requestId ?? "unavailable"}).");
                return 1;
            }

            Console.WriteLine(update ? "Customer label updated." : "Customer account created.");
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
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine($"Request canceled or timed out. {retryHint}");
            return 1;
        }
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
