#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$OidcOnly,
    [ValidateRange(1024,65535)][int]$PostgresPort = 55433,
    [ValidateRange(30,900)][int]$HealthTimeoutSeconds = 180,
    [string]$PostgresBinDirectory,
    [string]$PostgresClientBinDirectory,
    [string]$ElasticMqJar,
    [string]$KeycloakDirectory,
    [string]$JavaHome,
    [scriptblock]$OnVerified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
$runtime = Join-Path $workspaceRoot '.work/native-runtime'
$stateFile = Join-Path $runtime 'processes.json'
$envFile = Join-Path $infraRoot '.env'
$pgBin = if ($PostgresBinDirectory) { [IO.Path]::GetFullPath($PostgresBinDirectory) } else { Join-Path $workspaceRoot '.work/closure-pg-native/bin' }
$pgClientBin = if ($PostgresClientBinDirectory) { [IO.Path]::GetFullPath($PostgresClientBinDirectory) } else { Join-Path $workspaceRoot '.work/closure-pg-edb/pgsql/bin' }
if (-not $ElasticMqJar) { $ElasticMqJar = Join-Path $workspaceRoot '.work/elasticmq-1.6.12.jar' }
$identityArguments = @{}
if ($KeycloakDirectory) { $identityArguments.KeycloakDirectory = $KeycloakDirectory }
if ($JavaHome) { $identityArguments.JavaHome = $JavaHome }
$messagingArguments = @{ ElasticMqJar = $ElasticMqJar }
if ($JavaHome) { $messagingArguments.JavaHome = $JavaHome }
$databaseDirectory = Join-Path $runtime 'postgres'
$backendProject = Join-Path $workspaceRoot 'vortexbird-backend/src/VortexBird.API/VortexBird.API.csproj'
$apiDirectory = Join-Path $runtime 'api'
$frontendDirectory = Join-Path $workspaceRoot 'vortexbird-frontend'
$vite = Join-Path $frontendDirectory 'node_modules/vite/bin/vite.js'
$dotnet = (Get-Command dotnet.exe -CommandType Application -ErrorAction Stop).Source
$node = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
foreach ($path in @($envFile, $backendProject, $vite, (Join-Path $pgBin 'initdb.exe'), (Join-Path $pgBin 'postgres.exe'), (Join-Path $pgBin 'pg_ctl.exe'), (Join-Path $pgClientBin 'psql.exe'), (Join-Path $pgClientBin 'createdb.exe'), $ElasticMqJar)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing prerequisite: $path. See infrastructure/native-runtime.md; no service was started." }
}
$configuration = @{}
foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1, $value.Length - 2) }
        $configuration[$Matches[1]] = $value
    }
}
foreach ($name in @('POSTGRES_PASSWORD','DEMO_EMAIL','DEMO_PASSWORD','DEMO_SIGNING_KEY','KEYCLOAK_ADMIN_PASSWORD')) {
    if ([string]::IsNullOrWhiteSpace($configuration[$name])) { throw "Missing required $name in .env. Values were not printed or replaced." }
}
$apiPort = if ($configuration.API_PORT) { [int]$configuration.API_PORT } else { 5080 }
$frontendPort = if ($configuration.FRONTEND_PORT) { [int]$configuration.FRONTEND_PORT } else { 5173 }
$identityPort = if ($configuration.KEYCLOAK_PORT) { [int]$configuration.KEYCLOAK_PORT } else { 8080 }
$demoEnabled = if ($configuration.DEMO_ENABLED) { $configuration.DEMO_ENABLED.ToLowerInvariant() } else { 'true' }
$portalDemoEnabled = if ($configuration.VITE_DEMO_AUTH) { $configuration.VITE_DEMO_AUTH.ToLowerInvariant() } else { 'true' }
if ($OidcOnly) { $demoEnabled = 'false'; $portalDemoEnabled = 'false' }
if ($demoEnabled -notin @('true','false') -or $demoEnabled -ne $portalDemoEnabled) { throw 'DEMO_ENABLED and VITE_DEMO_AUTH must be matching boolean values. Configuration was not changed.' }
if ($frontendPort -ne 5173) { throw 'The imported native realm currently allows portal port 5173. Update the native realm redirects before changing the portal port.' }
$apiUrl = "http://127.0.0.1:$apiPort"
$portalUrl = "http://localhost:$frontendPort"
$identityUrl = "http://localhost:$identityPort"
& (Join-Path $PSScriptRoot 'Start-KeycloakNative.ps1') @identityArguments -Port $identityPort -ValidateOnly
& (Join-Path $PSScriptRoot 'Start-Native-Messaging.ps1') @messagingArguments -ValidateOnly
if ($ValidateOnly) {
    Write-Output "Native prerequisites: PASS. Ports API=$apiPort portal=$frontendPort identity=$identityPort PostgreSQL=$PostgresPort ElasticMQ=9324. Demo authentication=$demoEnabled. Redis disabled (optional cache). No processes, connections, builds or migrations were run."
    return
}

function Quote-Argument([string]$value) { '"' + (($value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$owned = @{}
if (Test-Path -LiteralPath $stateFile) {
    foreach ($entry in @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json)) { $owned[$entry.name] = $entry }
}
function Save-State { @($owned.Values) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8 }
function Start-Owned([string]$name, [string]$executable, [string[]]$arguments, [hashtable]$environment, [string]$directory, [int]$port) {
    try { $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq $port) }
    catch { throw "Cannot inspect local TCP listeners: $($_.Exception.Message). Port $port is unknown, not free. No $name process was started." }
    if ($owned.ContainsKey($name)) {
        $record = $owned[$name]
        $existing = Get-Process -Id $record.processId -ErrorAction SilentlyContinue
        if ($record.executable -eq $executable -and (Test-NativeProcessIdentity $existing $record.processId $record.startedAt $record.executable)) {
            if (@($listeners | Where-Object OwningProcess -ne $existing.Id).Count) {
                throw "Port $port has a listener outside the recorded $name process. Nothing was stopped."
            }
            return $existing
        }
    }
    if ($listeners.Count) { throw "Port $port is occupied by a process outside this launcher's ownership. Nothing was stopped." }
    $process = Start-Process -FilePath $executable -ArgumentList (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ') -Environment $environment -WorkingDirectory $directory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime "$name.stdout.log") -RedirectStandardError (Join-Path $runtime "$name.stderr.log")
    $owned[$name] = @{ name = $name; processId = $process.Id; startedAt = $process.StartTime.ToUniversalTime().ToString('o'); executable = $executable }
    Save-State
    return $process
}
function Run-Checked([string]$name, [string]$executable, [string[]]$arguments, [hashtable]$environment) {
    $process = Start-Process -FilePath $executable -ArgumentList (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ') -Environment $environment -WorkingDirectory $runtime -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime "$name.stdout.log") -RedirectStandardError (Join-Path $runtime "$name.stderr.log")
    $commandDeadline = [DateTime]::UtcNow.AddSeconds(180)
    while (-not $process.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -gt $commandDeadline) {
            $process.Kill($true)
            throw "$name exceeded 180 seconds; its owned process tree was stopped. Data and logs were preserved."
        }
    }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "$name failed (exit $($process.ExitCode)); inspect .work/native-runtime/$name.stderr.log. Readiness is not confirmed." }
}

function Test-DatabaseExistsResult([string]$resultPath) {
    # psql -At returns an empty file when the SELECT finds no matching database.
    # Get-Content -Raw returns $null for that file; ReadAllText always returns a string.
    $result = [IO.File]::ReadAllText($resultPath).Trim()
    switch ($result) {
        '' { return $false }
        '1' { return $true }
        default { throw 'Unexpected database existence result. No database was created; inspect database-exists.stdout.log.' }
    }
}

function Write-NativeVerification([string]$checkName) {
    if ($OnVerified) { & $OnVerified $checkName }
    Write-Output "Verified: $checkName"
}

try {
    # An unavailable CIM query is not evidence of free ports. Check read access
    # before initializing a new cluster or launching any service.
    try { $null = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) }
    catch { throw "Cannot inspect local TCP listeners: $($_.Exception.Message). No service was started. Run Diagnose-Local.ps1 in the normal Windows user session to distinguish this session's restrictions from machine configuration." }
    # Isolated data directory: never reinitialize or alter the older validation cluster.
    if (-not (Test-Path -LiteralPath (Join-Path $databaseDirectory 'PG_VERSION'))) {
        if ((Test-Path -LiteralPath $databaseDirectory) -and @(Get-ChildItem -LiteralPath $databaseDirectory -Force).Count -gt 0) { throw 'The new PostgreSQL directory contains files without PG_VERSION. It was preserved; inspect it manually.' }
        $passwordFile = Join-Path $runtime 'postgres-password.tmp'
        try {
            [IO.File]::WriteAllText($passwordFile, $configuration.POSTGRES_PASSWORD + "`n")
            Run-Checked 'postgres-init' (Join-Path $pgBin 'initdb.exe') @('-D',$databaseDirectory,'-U','vortexbird','-A','scram-sha-256','--encoding=UTF8','--pwfile',$passwordFile) @{}
        } finally { if (Test-Path -LiteralPath $passwordFile) { Remove-Item -LiteralPath $passwordFile } }
    }
    $pg = Start-Owned 'postgres' (Join-Path $pgBin 'postgres.exe') @('-D',$databaseDirectory,'-h','127.0.0.1','-p',"$PostgresPort") @{} $runtime $PostgresPort
    $pgEnvironment = @{ PGHOST = '127.0.0.1'; PGPORT = "$PostgresPort"; PGUSER = 'vortexbird'; PGPASSWORD = $configuration.POSTGRES_PASSWORD; PGDATABASE = 'postgres'; PGCONNECT_TIMEOUT = '3'; PGSSLMODE = 'disable' }
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $databaseReady = $false
    do {
        $pg.Refresh()
        if ($pg.HasExited) { throw 'PostgreSQL exited before readiness; inspect postgres.stderr.log.' }
        try {
            Run-Checked 'postgres-check' (Join-Path $pgClientBin 'psql.exe') @('-X','-w','-At','-v','ON_ERROR_STOP=1','-c','SELECT 1') $pgEnvironment
            $databaseReady = [IO.File]::ReadAllText((Join-Path $runtime 'postgres-check.stdout.log')).Trim() -eq '1'
        } catch { Start-Sleep -Seconds 1 }
    } while (-not $databaseReady -and [DateTime]::UtcNow -lt $deadline)
    if (-not $databaseReady) { throw 'PostgreSQL SQL readiness failed. Inspect postgres-check.stderr.log; a running process alone does not establish readiness.' }
    Write-NativeVerification 'PostgreSQL answered SELECT 1'
    Run-Checked 'database-exists' (Join-Path $pgClientBin 'psql.exe') @('-X','-w','-At','-v','ON_ERROR_STOP=1','-c',"SELECT 1 FROM pg_database WHERE datname='vortexbird'") $pgEnvironment
    if (-not (Test-DatabaseExistsResult (Join-Path $runtime 'database-exists.stdout.log'))) { Run-Checked 'database-create' (Join-Path $pgClientBin 'createdb.exe') @('-w','vortexbird') $pgEnvironment }

    & (Join-Path $PSScriptRoot 'Start-KeycloakNative.ps1') @identityArguments -Port $identityPort
    Write-NativeVerification 'Keycloak realm returned its configured issuer and PKCE S256'
    & (Join-Path $PSScriptRoot 'Start-Native-Messaging.ps1') @messagingArguments
    Write-NativeVerification 'ElasticMQ returned both configured queue URLs'
    Run-Checked 'api-publish' $dotnet @('publish',$backendProject,'-c','Release','-o',$apiDirectory,'--no-restore','/p:UseAppHost=false') @{}
    $connection = [System.Data.Common.DbConnectionStringBuilder]::new()
    $connection['Host'] = '127.0.0.1'; $connection['Port'] = "$PostgresPort"; $connection['Database'] = 'vortexbird'; $connection['Username'] = 'vortexbird'; $connection['Password'] = $configuration.POSTGRES_PASSWORD; $connection['SSL Mode'] = 'Disable'
    $apiEnvironment = @{
        ASPNETCORE_ENVIRONMENT = 'Development'; ASPNETCORE_URLS = $apiUrl
        ConnectionStrings__Database = $connection.ConnectionString; ConnectionStrings__Redis = ''
        Authentication__Authority = "$identityUrl/realms/vortexbird"; Authentication__ValidIssuer = "$identityUrl/realms/vortexbird"; Authentication__RequireHttpsMetadata = 'false'
        Authentication__DemoEnabled = $demoEnabled; Authentication__DemoSigningKey = $configuration.DEMO_SIGNING_KEY
        Demo__Email = $configuration.DEMO_EMAIL; Demo__Password = $configuration.DEMO_PASSWORD
        Database__Initialize = 'true'; Seed__Enabled = 'true'; Seed__AdminSubject = 'demo-admin'; Workers__Enabled = 'true'
        Cors__AllowedOrigins__0 = $portalUrl; Payments__Provider = 'Simulator'; Messaging__Provider = 'sqs'; Messaging__Region = 'us-east-2'
        Messaging__ServiceUrl = 'http://127.0.0.1:9324'; Messaging__QueueUrl = 'http://127.0.0.1:9324/000000000000/vortexbird-events'
        Messaging__VisibilityTimeoutSeconds = '120'; Messaging__MaxAttempts = '5'; AWS_REGION = 'us-east-2'
        AWS_ACCESS_KEY_ID = 'local-emulator-only'; AWS_SECRET_ACCESS_KEY = 'local-emulator-only'; AWS_EC2_METADATA_DISABLED = 'true'
    }
    $api = Start-Owned 'api' $dotnet @((Join-Path $apiDirectory 'VortexBird.API.dll')) $apiEnvironment $apiDirectory $apiPort
    $frontend = Start-Owned 'frontend' $node @($vite,'--host','127.0.0.1','--port',"$frontendPort",'--strictPort') @{
        API_PROXY_URL = $apiUrl; VITE_API_BASE_URL = '/api/v1'; VITE_KEYCLOAK_URL = $identityUrl; VITE_KEYCLOAK_REALM = 'vortexbird'; VITE_KEYCLOAK_CLIENT_ID = 'vortexbird-portal'; VITE_DEMO_AUTH = $demoEnabled
    } $frontendDirectory $frontendPort
    $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
    $ready = $false
    do {
        $api.Refresh(); $frontend.Refresh()
        if ($api.HasExited -or $frontend.HasExited) { throw 'API or frontend exited before readiness. Inspect their local logs.' }
        try {
            $health = Invoke-RestMethod -Uri "$apiUrl/health/ready" -TimeoutSec 3
            $portal = Invoke-WebRequest -Uri $portalUrl -TimeoutSec 3
            $discovery = Invoke-RestMethod -Uri "$identityUrl/realms/vortexbird/.well-known/openid-configuration" -TimeoutSec 3
            $ready = $health.status -eq 'ready' -and $portal.StatusCode -eq 200 -and $discovery.issuer -eq "$identityUrl/realms/vortexbird"
        } catch { $ready = $false }
        if (-not $ready) { Start-Sleep -Seconds 2 }
    } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw 'Native platform readiness failed. Do not treat running processes as a validated platform.' }
    if ($demoEnabled -eq 'true') {
        $loginBody = @{ email = $configuration.DEMO_EMAIL; password = $configuration.DEMO_PASSWORD } | ConvertTo-Json -Compress
        $login = Invoke-RestMethod -Method Post -Uri "$portalUrl/api/v1/auth/demo-login" -ContentType 'application/json' -Body $loginBody -TimeoutSec 10
        if ([string]::IsNullOrWhiteSpace($login.accessToken)) { throw 'Native demo login through the frontend failed.' }
        Write-Output 'Native demo login through frontend: PASS.'
    }
    Write-Output "Native platform health: PASS. Portal $portalUrl ; API $apiUrl ; Keycloak $identityUrl . Redis is disabled; business integrations and payments are simulated. Real OIDC flows still require the browser test."
} finally {
    $configuration.Clear(); $connection = $null; $apiEnvironment = $null; $pgEnvironment = $null; $login = $null; $loginBody = $null
}
