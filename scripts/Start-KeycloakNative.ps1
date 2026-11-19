#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$KeycloakDirectory,
    [string]$JavaHome = 'C:\Program Files\Eclipse Adoptium\jdk-25.0.1.8-hotspot',
    [ValidateRange(1024, 65535)][int]$Port = 8080,
    [ValidateRange(30, 900)][int]$TimeoutSeconds = 240,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Native-KeycloakRuntime.ps1')
$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
$runtimeRoot = Join-Path $workspaceRoot '.work/native-runtime'
$manifestPath = Join-Path $runtimeRoot 'keycloak-process.json'
if (-not $KeycloakDirectory) { $KeycloakDirectory = Join-Path $workspaceRoot '.work/validation-20261117/keycloak-26.4.0' }
$keycloakRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($KeycloakDirectory))
$workspacePrefix = [IO.Path]::GetFullPath($workspaceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $keycloakRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'KeycloakDirectory must be inside the VortexBird workspace; external installations are not modified.'
}
$java = Join-Path $JavaHome 'bin/java.exe'
$runner = Join-Path $keycloakRoot 'lib/quarkus-run.jar'
$realmSource = Join-Path $infraRoot 'keycloak/vortexbird-realm.json'
$envFile = Join-Path $infraRoot '.env'
foreach ($path in @($java, $runner, $realmSource, $envFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing prerequisite: $path" }
}
$launchLock = Enter-NativeKeycloakLock $manifestPath
try {
$localConfig = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $localConfig[$Matches[1].Trim()] = $Matches[2] }
}
foreach ($key in @('DEMO_EMAIL', 'DEMO_PASSWORD', 'KEYCLOAK_ADMIN_PASSWORD')) {
    if ([string]::IsNullOrWhiteSpace($localConfig[$key])) { throw "Missing $key in local .env; its contents were not modified." }
}
$realm = Get-Content -LiteralPath $realmSource -Raw | ConvertFrom-Json
if ($realm.realm -ne 'vortexbird') { throw 'Unexpected realm in the versioned Keycloak configuration.' }
$issuer = "http://localhost:$Port/realms/vortexbird"
if ($ValidateOnly) {
    $null = Resolve-NativeKeycloakRuntime $workspaceRoot $keycloakRoot $manifestPath $java -ValidateOnly
    Write-Output 'Keycloak native prerequisites valid. No files, processes, credentials or services were changed.'
    return
}

if (Test-Path -LiteralPath $manifestPath) {
    $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $running = Get-Process -Id $previous.pid -ErrorAction SilentlyContinue
    if (Test-NativeProcessIdentity $running $previous.pid $previous.startTimeUtc $previous.executable) {
        if ($previous.issuer -ne $issuer) { throw 'Tracked Keycloak uses a different port. Stop it explicitly before changing configuration.' }
        $discovery = Invoke-RestMethod -Uri "$issuer/.well-known/openid-configuration" -TimeoutSec 5
        if ($discovery.issuer -ne $issuer -or 'S256' -notin $discovery.code_challenge_methods_supported) {
            throw 'Existing Keycloak did not pass issuer and PKCE discovery checks.'
        }
        Write-Output "Keycloak READY (discovery + S256): $issuer"
        return
    }
}

$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try { $portProbe.Start() }
catch { throw "Loopback port $Port is already in use or unavailable. No process was started." }
finally { $portProbe.Stop() }

$runtime = Resolve-NativeKeycloakRuntime $workspaceRoot $keycloakRoot $manifestPath $java
$runner = $runtime.runner
if ($runtime.optimized) { $runner = Install-NativeKeycloakCompiledArtifacts $workspaceRoot $keycloakRoot $manifestPath $runner }
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
$importDirectory = Join-Path $keycloakRoot 'data/import'
New-Item -ItemType Directory -Path $importDirectory -Force | Out-Null
$importFile = Join-Path $importDirectory 'vortexbird-realm.json'
if (-not (Test-Path -LiteralPath $importFile)) {
    # This is a local synthetic identity. Imported realm data stays under ignored
    # .work and is never written into the versioned realm or included in reports.
    $user = [pscustomobject]@{
        id = 'demo-admin'; username = $localConfig.DEMO_EMAIL; email = $localConfig.DEMO_EMAIL
        enabled = $true; emailVerified = $true; firstName = 'Administrador'; lastName = 'AndesRetail'
        realmRoles = @('SUPER_ADMIN')
        attributes = @{ partner_id = @('11111111-1111-1111-1111-111111111111'); channel_id = @('22222222-2222-2222-2222-222222222222') }
        credentials = @(@{ type = 'password'; value = $localConfig.DEMO_PASSWORD; temporary = $false })
    }
    $realm | Add-Member -NotePropertyName users -NotePropertyValue @($user) -Force
    $realm | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $importFile -Encoding utf8
}

$variables = @{
    KC_BOOTSTRAP_ADMIN_USERNAME = $(if ($localConfig.KEYCLOAK_ADMIN) { $localConfig.KEYCLOAK_ADMIN } else { 'local-admin' })
    KC_BOOTSTRAP_ADMIN_PASSWORD = $localConfig.KEYCLOAK_ADMIN_PASSWORD
    KC_HOSTNAME = "http://localhost:$Port"
    KC_HTTP_HOST = '127.0.0.1'; KC_HTTP_PORT = [string]$Port; KC_HTTP_MANAGEMENT_HOST = '127.0.0.1'
    KC_HTTP_ENABLED = 'true'; KC_CACHE = 'local'
    KC_HEALTH_ENABLED = 'true'; KC_METRICS_ENABLED = 'true'
    KC_DB = 'dev-file'
}
$oldValues = @{}
$process = $null
$ready = $false
try {
    foreach ($key in $variables.Keys) {
        $oldValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $variables[$key], 'Process')
    }
    # Equivalent entrypoint to kc.bat, keeping the actual Java PID so stop can
    # verify ownership. Reaugmentation exit 10 is relaunched once as kc.bat does.
    $javaArgs = @(Get-NativeKeycloakJavaOptions $keycloakRoot)
    $command = if ($runtime.optimized) { @('start','--optimized') } else { @('--profile=dev','start-dev') }
    $entryArgs = @('-cp', $runner, 'io.quarkus.bootstrap.runner.QuarkusEntryPoint') + $command + '--import-realm'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $argsForAttempt = $javaArgs + $(if ($attempt -eq 1) { @('-Dkc.config.built=true') } else { @() }) + $entryArgs
        $quotedArgs = @($argsForAttempt | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
        $process = Start-Process -FilePath $java -ArgumentList $quotedArgs -WindowStyle Hidden -PassThru `
            -WorkingDirectory $keycloakRoot -RedirectStandardOutput (Join-Path $runtimeRoot "keycloak-$attempt.log") `
            -RedirectStandardError (Join-Path $runtimeRoot "keycloak-$attempt.error.log")
        $identity = [ordered]@{ pid = $process.Id; startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o'); executable = $process.Path; issuer = $issuer; directory = $keycloakRoot }
        $identity | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
        while ([DateTime]::UtcNow -lt $deadline) {
            $process.Refresh()
            if ($process.HasExited) { break }
            try {
                $discovery = Invoke-RestMethod -Uri "$issuer/.well-known/openid-configuration" -TimeoutSec 3
                if ($discovery.issuer -eq $issuer -and 'S256' -in $discovery.code_challenge_methods_supported) { $ready = $true; break }
            } catch { $lastDiscoveryError = $_.Exception.Message }
            Start-Sleep -Seconds 2
        }
        if ($ready) { break }
        $process.Refresh()
        if (-not $process.HasExited -or $process.ExitCode -ne 10) { break }
    }
    if (-not $ready) {
        $detail = if ($process.HasExited) { "Java exited with code $($process.ExitCode)." } else { "Discovery timeout. $lastDiscoveryError" }
        throw "Keycloak was not verified ready. $detail Review .work/native-runtime/keycloak-*.log. No authentication test is declared passed."
    }
    Write-Output "Keycloak READY (discovery + S256): $issuer"
    Write-Output 'The local synthetic identity uses DEMO_EMAIL/DEMO_PASSWORD from .env; no credentials are printed.'
} finally {
    foreach ($key in $oldValues.Keys) { [Environment]::SetEnvironmentVariable($key, $oldValues[$key], 'Process') }
    $localConfig = $null; $realm = $null; $user = $null; $variables = $null
    if (-not $ready -and $process) { & (Join-Path $PSScriptRoot 'Stop-KeycloakNative.ps1') }
}
} finally {
    $launchLock.ReleaseMutex()
    $launchLock.Dispose()
}
