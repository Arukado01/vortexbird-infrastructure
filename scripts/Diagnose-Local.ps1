#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$PostgresPort = 55433,
    [string]$PostgresBinDirectory,
    [string]$PostgresClientBinDirectory,
    [string]$ElasticMqJar,
    [string]$KeycloakDirectory,
    [string]$JavaHome = 'C:\Program Files\Eclipse Adoptium\jdk-25.0.1.8-hotspot'
)

# Read-only: no connections, binds, service/process starts, installs, environment
# changes, firewall changes, permission changes or output files. Redirect the JSON
# explicitly if a report file is wanted. Never include .env values or command lines.
$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
if (-not $PostgresBinDirectory) { $PostgresBinDirectory = Join-Path $workspaceRoot '.work/closure-pg-native/bin' }
if (-not $PostgresClientBinDirectory) { $PostgresClientBinDirectory = Join-Path $workspaceRoot '.work/closure-pg-edb/pgsql/bin' }
if (-not $ElasticMqJar) { $ElasticMqJar = Join-Path $workspaceRoot '.work/elasticmq-1.6.12.jar' }
if (-not $KeycloakDirectory) { $KeycloakDirectory = Join-Path $workspaceRoot '.work/validation-20261117/keycloak-26.4.0' }
$envFile = Join-Path $infraRoot '.env'
$configuration = @{}
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $configuration[$Matches[1]] = $value
        }
    }
}
function Read-Port([string]$name, [int]$fallback) {
    if (-not $configuration.ContainsKey($name)) { return $fallback }
    $portValue = 0
    if (-not [int]::TryParse($configuration[$name], [ref]$portValue) -or $portValue -lt 1024 -or $portValue -gt 65535) { return $null }
    return $portValue
}
$ports = [ordered]@{
    api = Read-Port 'API_PORT' 5080
    frontend = Read-Port 'FRONTEND_PORT' 5173
    keycloak = Read-Port 'KEYCLOAK_PORT' 8080
    keycloakManagement = 9000
    postgresNative = $PostgresPort
    elasticMq = 9324
}
$portsToInspect = @($ports.Values | Where-Object { $null -ne $_ } | Select-Object -Unique)
$prerequisitePaths = [ordered]@{
    localEnvironment = $envFile
    postgresInit = Join-Path $PostgresBinDirectory 'initdb.exe'
    postgresServer = Join-Path $PostgresBinDirectory 'postgres.exe'
    postgresControl = Join-Path $PostgresBinDirectory 'pg_ctl.exe'
    postgresClient = Join-Path $PostgresClientBinDirectory 'psql.exe'
    postgresCreateDatabase = Join-Path $PostgresClientBinDirectory 'createdb.exe'
    elasticMqJar = $ElasticMqJar
    keycloakRunner = Join-Path $KeycloakDirectory 'lib/quarkus-run.jar'
    javaExplicit = Join-Path $JavaHome 'bin/java.exe'
    frontendVite = Join-Path $workspaceRoot 'vortexbird-frontend/node_modules/vite/bin/vite.js'
    backendRestoreAssets = Join-Path $workspaceRoot 'vortexbird-backend/src/VortexBird.API/obj/project.assets.json'
}
$prerequisites = @(
    foreach ($entry in $prerequisitePaths.GetEnumerator()) {
        [ordered]@{ name = $entry.Key; path = $entry.Value; exists = [bool](Test-Path -LiteralPath $entry.Value -PathType Leaf) }
    }
)
$requiredKeys = @('POSTGRES_PASSWORD','DEMO_EMAIL','DEMO_PASSWORD','DEMO_SIGNING_KEY','KEYCLOAK_ADMIN_PASSWORD')
$missingKeys = @($requiredKeys | Where-Object { [string]::IsNullOrWhiteSpace($configuration[$_]) })
$commands = @(
    foreach ($name in @('pwsh.exe','dotnet.exe','node.exe','java.exe','docker.exe','netsh.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        [ordered]@{ name = $name; available = [bool]$command; path = $(if ($command) { $command.Source } else { $null }) }
    }
)
$listeners = [ordered]@{ status = 'unknown'; entries = @(); error = $null }
try {
    $listeners.entries = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -in $portsToInspect } |
        Select-Object LocalAddress, LocalPort, OwningProcess)
    $listeners.status = 'observed'
} catch { $listeners.error = $_.Exception.Message }

$processes = [ordered]@{ status = 'unknown'; entries = @(); error = $null }
try {
    $processes.entries = @(Get-Process -ErrorAction Stop |
        Where-Object { $_.ProcessName -match '^(java|postgres|dotnet|node|Docker Desktop|com\.docker\.backend|pwsh)$' } |
        Select-Object ProcessName, Id)
    $processes.status = 'observed-visible-session-only'
} catch { $processes.error = $_.Exception.Message }

$excludedPorts = @(
    foreach ($family in @('ipv4','ipv6')) {
        $item = [ordered]@{ family = $family; status = 'unknown'; ranges = @(); matchingPorts = @(); diagnostic = $null }
        $netsh = Get-Command netsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($netsh) {
            try {
                $output = & $netsh.Source interface $family show excludedportrange protocol=tcp 2>&1
                $exitCode = $LASTEXITCODE
                if ($exitCode -eq 0) {
                    $item.status = 'observed'
                    $item.ranges = @(
                        foreach ($outputLine in $output) {
                            if ([string]$outputLine -match '^\s*(\d+)\s+(\d+)\s*(\*)?\s*$') {
                                [ordered]@{ start = [int]$Matches[1]; end = [int]$Matches[2]; administrativelyExcluded = [bool]$Matches[3] }
                            }
                        }
                    )
                    $item.matchingPorts = @(
                        foreach ($range in $item.ranges) {
                            $portsToInspect | Where-Object { $_ -ge $range.start -and $_ -le $range.end }
                        }
                    )
                } else { $item.diagnostic = "netsh exited $exitCode`: " + (($output | ForEach-Object { [string]$_ }) -join ' ') }
            } catch { $item.diagnostic = $_.Exception.Message }
        } else { $item.diagnostic = 'netsh.exe is not available.' }
        $item
    }
)

$notes = @(
    'This report made no socket connection attempts and did not start any service.',
    'Unknown listener or excluded-port status is not evidence that a port is free.',
    'Process entries cover only what this execution session can observe.',
    'Socket error 10013 alone does not identify whether the cause is the agent sandbox, Windows policy, reserved ports or another networking control.',
    'Compare this report with the same read-only diagnostic run in the normal Windows user session before attributing the cause.',
    'Native PostgreSQL uses -PostgresPort, not POSTGRES_PORT from the Docker .env settings.',
    'The portal realm redirects currently require frontend port 5173.',
    'Installed file presence does not prove runtime compatibility, health, migrations or authentication.'
)
$report = [ordered]@{
    checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    mode = 'read-only-no-network'
    powerShell = $PSVersionTable.PSVersion.ToString()
    nativePowerShellMinimumMet = $PSVersionTable.PSVersion -ge [version]'7.4'
    configuredNativePorts = $ports
    prerequisites = $prerequisites
    missingEnvironmentKeys = $missingKeys
    commands = $commands
    listeners = $listeners
    excludedTcpPorts = $excludedPorts
    visibleProcesses = $processes
    notes = $notes
}
$configuration.Clear()
$report | ConvertTo-Json -Depth 10
