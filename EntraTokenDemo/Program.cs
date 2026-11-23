using System.Buffers.Text;
using System.Text.Json;
using Microsoft.Identity.Client;

if (args is ["create-user" or "update-user", ..])
{
    return await UserCommands.RunAsync(args[1..], update: args[0] == "update-user");
}

if (args is ["client-credentials", ..])
{
    return await RunClientCredentialsAsync(args[1..]);
}

var raw = args.Length == 4 && args[3] == "--raw";
if ((args.Length != 3 && !raw) ||
    !Guid.TryParse(args[0], out var clientId) ||
    !Uri.TryCreate(args[1], UriKind.Absolute, out var authority) ||
    authority.Scheme != Uri.UriSchemeHttps ||
    string.IsNullOrWhiteSpace(args[2]))
{
    Console.Error.WriteLine("Usage: dotnet run -- <cli-client-id> <https-authority> <api-scope> [--raw]");
    PrintClientCredentialsUsage();
    UserCommands.PrintUsage();
    return 2;
}

var builder = PublicClientApplicationBuilder.Create(clientId.ToString())
    .WithRedirectUri("http://localhost");

if (authority.Host.EndsWith(".b2clogin.com", StringComparison.OrdinalIgnoreCase))
{
    builder.WithB2CAuthority(authority.AbsoluteUri);
}
else if (authority.Host.EndsWith(".ciamlogin.com", StringComparison.OrdinalIgnoreCase))
{
    builder.WithAuthority(authority.AbsoluteUri);
}
else
{
    Console.Error.WriteLine("Use your tenant's b2clogin.com or ciamlogin.com authority.");
    return 2;
}

try
{
    Console.Error.WriteLine("Complete sign-in in your browser.");
    var result = await builder.Build()
        .AcquireTokenInteractive([args[2]])
        .WithUseEmbeddedWebView(false)
        .ExecuteAsync();

    return PrintAccessToken(result.AccessToken, raw);
}
catch (MsalException ex)
{
    Console.Error.WriteLine($"Sign-in failed: {ex.ErrorCode} (correlation ID: {ex.CorrelationId}).");
    return 1;
}

static async Task<int> RunClientCredentialsAsync(string[] arguments)
{
    var raw = arguments is [_, _, "--raw"];
    if ((arguments.Length != 2 && !raw) ||
        !Uri.TryCreate(arguments[0], UriKind.Absolute, out var authority) ||
        authority.Scheme != Uri.UriSchemeHttps ||
        !authority.Host.EndsWith(".ciamlogin.com", StringComparison.OrdinalIgnoreCase) ||
        !authority.IsDefaultPort || authority.UserInfo.Length != 0 ||
        authority.Query.Length != 0 || authority.Fragment.Length != 0 ||
        (authority.AbsolutePath != "/" &&
         !Guid.TryParseExact(authority.AbsolutePath.Trim('/'), "D", out _)))
    {
        PrintClientCredentialsUsage();
        return 2;
    }

    var defaultScope = arguments[1];
    if (!Uri.TryCreate(defaultScope, UriKind.Absolute, out var apiScope) ||
        apiScope.Scheme is not ("api" or "https") ||
        apiScope.Host.Length == 0 || apiScope.UserInfo.Length != 0 ||
        defaultScope.Any(char.IsWhiteSpace) ||
        !defaultScope.EndsWith("/.default", StringComparison.Ordinal) ||
        apiScope.Query.Length != 0 || apiScope.Fragment.Length != 0)
    {
        Console.Error.WriteLine("Use the API's full Application ID URI followed by /.default, not a delegated scope.");
        return 2;
    }

    if (!Guid.TryParse(Environment.GetEnvironmentVariable("ENTRA_M2M_CLIENT_ID"), out var clientId) ||
        clientId == Guid.Empty)
    {
        Console.Error.WriteLine("Set ENTRA_M2M_CLIENT_ID to the confidential app's Application (client) ID.");
        return 2;
    }
    var clientSecret = Environment.GetEnvironmentVariable("ENTRA_M2M_CLIENT_SECRET");
    if (string.IsNullOrWhiteSpace(clientSecret))
    {
        Console.Error.WriteLine("Set ENTRA_M2M_CLIENT_SECRET to the client secret Value, not its Secret ID.");
        return 2;
    }

    try
    {
        var result = await ConfidentialClientApplicationBuilder.Create(clientId.ToString())
            .WithAuthority(authority.AbsoluteUri)
            .WithClientSecret(clientSecret)
            .Build()
            .AcquireTokenForClient([defaultScope])
            .ExecuteAsync();

        return PrintAccessToken(result.AccessToken, raw);
    }
    catch (MsalException ex)
    {
        Console.Error.WriteLine($"Client credentials failed: {ex.ErrorCode} (correlation ID: {ex.CorrelationId}).");
        return 1;
    }
}

static void PrintClientCredentialsUsage() =>
    Console.Error.WriteLine("Usage: dotnet run -- client-credentials https://<tenant>.ciamlogin.com/ <api-default-scope> [--raw]");

static int PrintAccessToken(string? accessToken, bool raw)
{
    if (string.IsNullOrEmpty(accessToken))
    {
        Console.Error.WriteLine("MSAL did not return an access token.");
        return 1;
    }

    if (raw)
    {
        Console.WriteLine(accessToken);
        return 0;
    }

    var parts = accessToken.Split('.');
    if (parts is not { Length: 3 } || parts[1].Length == 0)
    {
        Console.Error.WriteLine("The access token is not a readable JWT. Request a scope for your own API.");
        return 1;
    }

    try
    {
        using var payload = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1]));
        if (payload.RootElement.ValueKind != JsonValueKind.Object)
        {
            Console.Error.WriteLine("The access token payload is not a JSON object.");
            return 1;
        }

        Console.WriteLine(JsonSerializer.Serialize(payload.RootElement, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }
    catch (Exception ex) when (ex is FormatException or JsonException)
    {
        Console.Error.WriteLine("The access token payload could not be decoded.");
        return 1;
    }
}
