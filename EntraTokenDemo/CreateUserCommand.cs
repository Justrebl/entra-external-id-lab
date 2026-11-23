using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Mail;
using System.Text;
using Microsoft.Identity.Client;

internal static class CreateUserCommand
{
    private const string AttributeName = "Customer_Label";
    private const string AuthoritySuffix = ".ciamlogin.com";

    public static void PrintUsage() =>
        Console.Error.WriteLine("       dotnet run -- create-user <https-authority> <email> <given-name> <surname> \"customer_label:<value>\"");

    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length != 5)
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

        var email = args[1].Trim();
        var givenName = args[2].Trim();
        var surname = args[3].Trim();
        if (!MailAddress.TryCreate(email, out var address) || address.Address != email ||
            givenName.Length == 0 || surname.Length == 0)
        {
            Console.Error.WriteLine("Provide a plain email address, a given name, and a surname.");
            return 2;
        }

        var separator = args[4].IndexOf(':');
        if (separator < 0 ||
            !args[4][..separator].Trim().Equals(AttributeName, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(args[4][(separator + 1)..]))
        {
            Console.Error.WriteLine("Provide customer_label:<value> with a non-empty value.");
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
        if (Console.IsInputRedirected)
        {
            Console.Error.WriteLine("Run create-user in an interactive terminal for the masked password prompt.");
            return 2;
        }

        var tenantDomain = $"{tenant}.onmicrosoft.com";
        try
        {
            Console.Error.WriteLine($"Sign in to {tenantDomain} with an account authorized to create users.");
            var result = await PublicClientApplicationBuilder.Create(clientId.ToString())
                .WithAuthority($"https://login.microsoftonline.com/{tenantDomain}")
                .WithRedirectUri("http://localhost")
                .Build()
                .AcquireTokenInteractive(["https://graph.microsoft.com/User.ReadWrite.All"])
                .WithUseEmbeddedWebView(false)
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync();

            var password = ReadPassword();
            if (string.IsNullOrWhiteSpace(password))
            {
                Console.Error.WriteLine("No password entered; no account was created.");
                return 2;
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
                [$"extension_{extensionsId:N}_{AttributeName}"] = args[4][(separator + 1)..].Trim()
            };

            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
            {
                Timeout = TimeSpan.FromSeconds(30)
            };
            http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", result.AccessToken);
            using var response = await http.PostAsJsonAsync("https://graph.microsoft.com/v1.0/users", user);
            if (response.StatusCode != HttpStatusCode.Created)
            {
                var requestId = response.Headers.TryGetValues("request-id", out var values)
                    ? values.FirstOrDefault() : null;
                Console.Error.WriteLine($"Graph did not report creation: HTTP {(int)response.StatusCode} (request ID: {requestId ?? "unavailable"}).");
                return 1;
            }

            Console.WriteLine("Customer account created.");
            return 0;
        }
        catch (MsalException ex)
        {
            Console.Error.WriteLine($"Admin sign-in failed: {ex.ErrorCode} (correlation ID: {ex.CorrelationId}).");
            return 1;
        }
        catch (HttpRequestException ex)
        {
            Console.Error.WriteLine($"Graph request failed: {ex.HttpRequestError}. Check whether the account exists before retrying.");
            return 1;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Request canceled or timed out. Check whether the account exists before retrying.");
            return 1;
        }
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
