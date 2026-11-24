$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
dotnet build "$repoRoot\EntraTokenDemo" --nologo --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'CLI build failed.' }

$assembly = [System.Reflection.Assembly]::LoadFrom("$repoRoot\EntraTokenDemo\bin\Debug\net10.0\EntraTokenDemo.dll")
$report = $assembly.GetType('UserCommands').GetMethod('ReportGraphStatusAsync', [System.Reflection.BindingFlags]'NonPublic,Static')
$http = [System.Net.Http.HttpClient]::new()
$http.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', 'synthetic-token')
try {
    $cases = @(
        @{
            Body = '{"error":{"code":"Request_BadRequest","message":"Rejected synthetic-password and synthetic-token\nCheck the property.","innerError":{"secret":"do-not-print"}}}'
            Expected = @('HTTP 400', 'request ID: offline-request', 'Graph error code: Request_BadRequest', 'Graph error message: Rejected [REDACTED] and [REDACTED] Check the property.')
        },
        @{ Body = '<html>synthetic-password</html>'; Expected = @('HTTP 400', 'response was not valid JSON') },
        @{ Body = '[]'; Expected = @('no structured error returned') },
        @{ Body = '{"error":{"code":42,"message":null}}'; Expected = @('no error code or message returned') },
        @{
            Body = (@{error = @{message = 'x' * 2000}} | ConvertTo-Json -Compress)
            Expected = @('Graph error message: ' + ('x' * 1024))
        }
    )
    foreach ($case in $cases) {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
        $response.Content = [System.Net.Http.StringContent]::new($case.Body)
        $response.Headers.Add('request-id', 'offline-request')
        $writer = [System.IO.StringWriter]::new()
        $originalError = [Console]::Error
        try {
            [Console]::SetError($writer)
            $task = $report.Invoke($null, [object[]]@('Graph did not report creation', $response, $http, 'synthetic-password'))
            [void]$task.GetAwaiter().GetResult()
            $output = $writer.ToString()
            foreach ($expected in $case.Expected) {
                if (-not $output.Contains($expected)) { throw "Missing diagnostic: $expected" }
            }
            if ($output -match 'synthetic-password|synthetic-token|do-not-print' -or
                $output.Contains('x' * 1025)) {
                throw 'Diagnostics leaked secrets or exceeded the message limit.'
            }
        } finally {
            [Console]::SetError($originalError)
            $writer.Dispose()
            $response.Dispose()
        }
    }
    Write-Host 'Offline Graph error diagnostic checks passed.'
} finally {
    $http.Dispose()
}
