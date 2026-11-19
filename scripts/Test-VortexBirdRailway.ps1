#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $ProjectId,
    [Parameter(Mandatory)] [guid] $EnvironmentId,
    [string] $RailwayCli,
    [switch] $Authenticated,
    [securestring] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ProjectId -eq [guid]::Empty -or $EnvironmentId -eq [guid]::Empty) {
    throw 'Specify the existing Railway VortexBird project and environment IDs.'
}
if ($AccessToken -and -not $Authenticated) { throw '-AccessToken requires -Authenticated.' }
if (-not $RailwayCli) {
    $command = Get-Command railway.exe, railway.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'Railway CLI was not found. Use the Windows PowerShell session where Railway CLI is installed and authenticated.' }
    $RailwayCli = $command.Source
}

$target = @('--project', $ProjectId.ToString(), '--environment', $EnvironmentId.ToString())

function Invoke-RailwayRead([string[]] $Arguments) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $RailwayCli @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw ('Railway CLI exited {0} for railway {1}. CLI diagnostics were withheld to protect deployment data.' -f $LASTEXITCODE, ($Arguments -join ' '))
    }
    return $output
}

function Read-Json([string] $Text, [string] $Label) {
    try { ConvertFrom-Json -InputObject $Text -ErrorAction Stop }
    catch { throw "$Label returned invalid JSON." }
}

function Get-Endpoint([string] $Service) {
    $raw = (Invoke-RailwayRead (@('domain', 'list', '--service', $Service, '--json') + $target)) -join "`n"
    $data = Read-Json $raw "Railway domain list for $Service"
    if (-not $data -or -not $data.PSObject.Properties['domains']) { throw "Railway did not return a domain list for $Service." }
    $domains = @($data.domains | Where-Object { $_.type -eq 'service' -and $_.domain -match '^[a-z0-9][a-z0-9-]*\.up\.railway\.app$' })
    if ($domains.Count -ne 1) { throw "Expected exactly one generated Railway HTTPS domain for $Service." }
    $domain = $domains[0]
    if ($null -ne $domain.targetPort -and ($domain.targetPort -lt 1 -or $domain.targetPort -gt 65535)) {
        throw "Railway reported an invalid target port for $Service."
    }
    [pscustomobject] @{ Origin = 'https://' + $domain.domain; TargetPort = $domain.targetPort }
}

function Invoke-Endpoint([string] $Origin, [string] $Path, [string] $Method = 'GET', [hashtable] $Headers = @{}) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), ($Origin + $Path))
    $response = $null
    try {
        foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string] $Headers[$key]) }
        try { $response = $http.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw "HTTPS request failed for $Method $Origin$Path. Verify DNS, certificate validation and service availability." }
        $responseHeaders = @{}
        foreach ($header in $response.Headers) { $responseHeaders[$header.Key] = $header.Value -join ', ' }
        $body = if ($response.Content) { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' }
        [pscustomobject] @{
            Status = [int] $response.StatusCode
            Headers = $responseHeaders
            Body = $body
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Assert-Status($Response, [int] $Expected, [string] $Label) {
    if ($Response.Status -ne $Expected) { throw "$Label returned HTTP $($Response.Status), expected $Expected." }
}

Add-Type -AssemblyName System.Net.Http
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(20)
$report = [ordered] @{
    ProjectId = $ProjectId.ToString()
    EnvironmentId = $EnvironmentId.ToString()
    Services = [ordered] @{}
    Checks = [ordered] @{ Authenticated = 'not_requested' }
    State = 'incomplete'
}
$checks = $report.Checks
$bearer = $null
$authHeaders = $null

try {
    foreach ($service in @('vortexbird-postgres', 'vortexbird-api', 'vortexbird-frontend', 'vortexbird-worker')) {
        $raw = (Invoke-RailwayRead (@('deployment', 'list', '--service', $service, '--limit', '1', '--json') + $target)) -join "`n"
        if (-not $raw.TrimStart().StartsWith('[')) { throw "Railway did not return the deployment array for $service." }
        $deployments = @(Read-Json $raw "Railway deployment list for $service")
        if (-not $deployments -or -not $deployments[0]) { throw "No deployment found for $service." }
        # Windows PowerShell can return a JSON array as a single pipeline object.
        $deployment = @($deployments[0])[0]
        $deploymentGuid = [guid]::Empty
        if (-not [guid]::TryParse([string] $deployment.id, [ref] $deploymentGuid) -or $deployment.status -notmatch '^[A-Z_]+$') {
            throw "Railway returned invalid deployment metadata for $service."
        }
        $report.Services[$service] = [ordered] @{ DeploymentId = $deploymentGuid.ToString(); Status = $deployment.status }
        $logArgs = @('logs', $deploymentGuid.ToString(), '--service', $service, '--lines', '50', '--json') + $target
        $entries = @(Invoke-RailwayRead $logArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $errorEntries = 0
        foreach ($line in $entries) {
            $entry = Read-Json $line "Railway logs for $service"
            $level = $entry.PSObject.Properties['level']
            if ($level -and $level.Value -match '^(error|fatal|critical)$') { $errorEntries++ }
        }
        $report.Services[$service].LogLinesExamined = $entries.Count
        $report.Services[$service].ErrorLevelLogLines = $errorEntries
    }
    $unhealthy = @($report.Services.GetEnumerator() | Where-Object { $_.Value.Status -ne 'SUCCESS' } | ForEach-Object { "$($_.Key)=$($_.Value.Status)" })
    if ($unhealthy.Count) { throw ('Services with a non-successful latest deployment: ' + ($unhealthy -join ', ')) }

    $api = Get-Endpoint 'vortexbird-api'
    $frontend = Get-Endpoint 'vortexbird-frontend'
    $report.Api = $api
    $report.Frontend = $frontend

    $live = Invoke-Endpoint $api.Origin '/health/live'
    $checks.ApiHealth = $live.Status
    Assert-Status $live 200 'API liveness'
    $ready = Invoke-Endpoint $api.Origin '/health/ready'
    $checks.ApiReadiness = $ready.Status
    Assert-Status $ready 200 'API readiness'
    if ((Read-Json $ready.Body 'API readiness').status -ne 'ready') { throw 'The readiness response did not confirm database connectivity and applied migrations.' }
    $checks.DatabaseConnectedAndMigrationsCurrent = $true
    $web = Invoke-Endpoint $frontend.Origin '/health'
    $checks.FrontendHealth = $web.Status
    Assert-Status $web 200 'Frontend health'
    Assert-Status (Invoke-Endpoint $frontend.Origin '/') 200 'Frontend home'

    $configuration = Invoke-Endpoint $api.Origin '/api/v1/auth/config'
    Assert-Status $configuration 200 'API public authentication configuration'
    $authConfig = Read-Json $configuration.Body 'API public authentication configuration'
    $runtime = Invoke-Endpoint $frontend.Origin '/config.js'
    Assert-Status $runtime 200 'Frontend runtime configuration'
    if ($runtime.Body -notmatch '(?s)^\s*window\.__VORTEX_CONFIG__\s*=\s*(\{.*\})\s*;\s*$') { throw 'Frontend runtime configuration format is invalid.' }
    $clientConfig = Read-Json $Matches[1] 'Frontend runtime configuration'
    if ($authConfig.provider -ne 'cognito' -or $authConfig.demoEnabled -isnot [bool] -or $authConfig.demoEnabled -or
        $authConfig.authority -notmatch '^https://cognito-idp\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9-]+_[A-Za-z0-9]+$' -or
        $authConfig.authorizationOrigin -notmatch '^https://[a-z0-9-]+\.auth\.[a-z0-9-]+\.amazoncognito\.com$' -or
        $authConfig.clientId -notmatch '^[a-z0-9]+$' -or ($authConfig.scope -split ' ') -notcontains 'vortexbird-api/access' -or
        $clientConfig.VITE_OIDC_PROVIDER -ne 'cognito' -or $clientConfig.VITE_DEMO_AUTH -ne 'false' -or
        $clientConfig.VITE_COGNITO_ISSUER -ne $authConfig.authority -or $clientConfig.VITE_COGNITO_CLIENT_ID -ne $authConfig.clientId -or
        $clientConfig.VITE_COGNITO_AUTHORIZATION_ORIGIN -ne $authConfig.authorizationOrigin -or
        $clientConfig.VITE_API_BASE_URL -ne "$($api.Origin)/api/v1") {
        throw 'The Railway frontend and API do not agree on Cognito or the HTTPS API origin.'
    }
    $checks.CognitoConfigurationMatched = $true

    $cors = Invoke-Endpoint $api.Origin '/api/v1/auth/me' 'OPTIONS' @{
        Origin = $frontend.Origin
        'Access-Control-Request-Method' = 'GET'
        'Access-Control-Request-Headers' = 'authorization'
    }
    $checks.CorsPreflight = $cors.Status
    if ($cors.Status -notin @(200, 204) -or $cors.Headers['Access-Control-Allow-Origin'] -ne $frontend.Origin -or
        ($cors.Headers['Access-Control-Allow-Headers'] -split '\s*,\s*') -notcontains 'authorization') {
        throw 'The API did not accept the Railway frontend origin and Authorization header in its CORS preflight.'
    }
    $anonymous = Invoke-Endpoint $api.Origin '/api/v1/auth/me'
    $checks.AnonymousAuthentication = $anonymous.Status
    Assert-Status $anonymous 401 'Anonymous API access'

    if ($Authenticated) {
        $checks.Authenticated = 'incomplete'
        if (-not $AccessToken) { $AccessToken = Read-Host 'Cognito access token from an existing account (hidden; do not enter a password)' -AsSecureString }
        $bearer = [Net.NetworkCredential]::new('', $AccessToken).Password
        if ($bearer.Length -gt 16384 -or $bearer -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
            throw 'The supplied credential does not have the expected signed JWT format.'
        }
        $authHeaders = @{ Authorization = 'Bearer ' + $bearer; Origin = $frontend.Origin }
        $me = Invoke-Endpoint $api.Origin '/api/v1/auth/me' 'GET' $authHeaders
        $checks.AuthenticatedAuthMe = $me.Status
        Assert-Status $me 200 'Authenticated API access'
        $session = Read-Json $me.Body 'Authenticated API access'
        if (-not $session.user -or -not $session.user.id -or $session.permissions -isnot [array] -or
            ($session.permissions -notcontains 'dashboard.read' -and $session.permissions -notcontains '*')) {
            throw 'The accepted token did not resolve to a VortexBird user with dashboard permissions.'
        }
        $checks.EffectivePermissionCount = $session.permissions.Count
        $dashboard = Invoke-Endpoint $api.Origin '/api/v1/dashboard?days=30' 'GET' $authHeaders
        $checks.AuthenticatedDashboard = $dashboard.Status
        Assert-Status $dashboard 200 'Authenticated dashboard'
        $metrics = (Read-Json $dashboard.Body 'Authenticated dashboard').metrics
        if (-not $metrics -or ($metrics.totalOrders -isnot [int] -and $metrics.totalOrders -isnot [long]) -or $metrics.totalOrders -lt 0) {
            throw 'The dashboard did not return a nonnegative totalOrders aggregate.'
        }
        $checks.DashboardTotalOrders = $metrics.totalOrders
        if ($session.permissions -contains 'permissions.read' -or $session.permissions -contains '*') {
            $permissions = Invoke-Endpoint $api.Origin '/api/v1/permissions?page=1&pageSize=10' 'GET' $authHeaders
            $checks.PermissionCatalog = $permissions.Status
            Assert-Status $permissions 200 'VortexBird permission catalog'
        }
        $checks.Authenticated = 'passed'
    }
    $report.State = if ($Authenticated) { 'public_and_authenticated_api_checks_passed' } else { 'public_checks_passed_authenticated_checks_pending' }
}
finally {
    $authHeaders = $null
    $bearer = $null
    $http.Dispose()
    [pscustomobject] $report | ConvertTo-Json -Depth 6
}
