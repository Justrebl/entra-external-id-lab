using System.Buffers.Text;
using System.Text.Json;
using Microsoft.Identity.Client;

if (args is ["create-user", ..])
{
    return await CreateUserCommand.RunAsync(args[1..]);
}

var raw = args.Length == 4 && args[3] == "--raw";
if ((args.Length != 3 && !raw) ||
    !Guid.TryParse(args[0], out var clientId) ||
    !Uri.TryCreate(args[1], UriKind.Absolute, out var authority) ||
    authority.Scheme != Uri.UriSchemeHttps ||
    string.IsNullOrWhiteSpace(args[2]))
{
    Console.Error.WriteLine("Usage: dotnet run -- <cli-client-id> <https-authority> <api-scope> [--raw]");
    CreateUserCommand.PrintUsage();
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

    var accessToken = result.AccessToken;
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

    using var payload = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1]));
    if (payload.RootElement.ValueKind != JsonValueKind.Object)
    {
        Console.Error.WriteLine("The access token payload is not a JSON object.");
        return 1;
    }

    Console.WriteLine(JsonSerializer.Serialize(payload.RootElement, new JsonSerializerOptions { WriteIndented = true }));
    return 0;
}
catch (MsalException ex)
{
    Console.Error.WriteLine($"Sign-in failed: {ex.ErrorCode} (correlation ID: {ex.CorrelationId}).");
    return 1;
}
catch (Exception ex) when (ex is FormatException or JsonException)
{
    Console.Error.WriteLine("The access token payload could not be decoded.");
    return 1;
}
