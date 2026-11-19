#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $ProjectId,
    [Parameter(Mandatory)] [guid] $EnvironmentId,
    [Parameter(Mandatory)] [guid] $DatabaseServiceId,
    [Parameter(Mandatory)] [string] $RailwayCli,
    [securestring] $MigratorPassword,
    [securestring] $ApiPassword,
    [securestring] $WorkerPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Provisioning requires Windows so the credential checkpoint is protected by Windows DPAPI.'
}
if (@($ProjectId, $EnvironmentId, $DatabaseServiceId) -contains [guid]::Empty) {
    throw 'Use the verified Railway project, environment and service IDs.'
}

function Invoke-RailwayCommand([string[]] $Arguments, [string] $InputText) {
    # Capture both output streams so a CLI or database error cannot echo a credential.
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = [Text.Encoding]::ASCII
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $output = $InputText | & $RailwayCli @Arguments 2>&1
    }
    else {
        $output = & $RailwayCli @Arguments 2>&1
    }
    [pscustomobject] @{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
}

function Invoke-RailwayQuery([string] $Query, [string[]] $Variables) {
    $response = Invoke-RailwayCommand (@('api', '--compact', $Query) + $Variables)
    if ($response.ExitCode -ne 0) { throw "Railway CLI could not verify the PostgreSQL target (exit $($response.ExitCode))." }
    $result = $response.Text | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'errors') { throw 'Railway rejected the PostgreSQL target verification query.' }
    if ($result.PSObject.Properties.Name -contains 'data') { return $result.data }
    return $result
}

$project = (Invoke-RailwayQuery 'query ($id: String!) { project(id: $id) { id name environments { edges { node { id name } } } services { edges { node { id name } } } } }' @('--raw-var', "id=$ProjectId")).project
if ($project.id -ne "$ProjectId" -or $project.name -cne 'VortexBird' -or
    @($project.environments.edges | Where-Object { $_.node.id -eq "$EnvironmentId" -and $_.node.name -ceq 'production' }).Count -ne 1 -or
    @($project.services.edges | Where-Object { $_.node.id -eq "$DatabaseServiceId" -and $_.node.name -ceq 'vortexbird-postgres' }).Count -ne 1) {
    throw 'The selected service must be vortexbird-postgres in the production environment of VortexBird.'
}
$network = Invoke-RailwayQuery 'query ($serviceId: String!, $environmentId: String!) { tcpProxies(serviceId: $serviceId, environmentId: $environmentId) { id } }' @('--raw-var', "serviceId=$DatabaseServiceId", '--raw-var', "environmentId=$EnvironmentId")
if (@($network.tcpProxies).Count -ne 0) { throw 'VortexBird PostgreSQL has a public TCP proxy. Keep the database private before provisioning.' }

# Railway CLI leaves stdin/stdout without a PTY for piped commands.
$sshArguments = @('ssh', '--project', "$ProjectId", '--environment', "$EnvironmentId", '--service', "$DatabaseServiceId", '--', 'sh', '-s')
$remoteHeader = @'
set -eu
if [ "${RAILWAY_PROJECT_ID:-}" != "$(PROJECT)" ] ||
   [ "${RAILWAY_ENVIRONMENT_ID:-}" != "$(ENVIRONMENT)" ] ||
   [ "${RAILWAY_SERVICE_ID:-}" != "$(SERVICE)" ]; then
  exit 61
fi
PGHOST="${RAILWAY_PRIVATE_DOMAIN:-}"
case "$PGHOST" in *.railway.internal) ;; *) exit 62 ;; esac
PGPORT="${PGPORT:-5432}"
case "$PGPORT" in *[!0-9]*|'') exit 63 ;; esac
PGUSER="${POSTGRES_USER:-${PGUSER:-}}"
PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}"
[ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] || exit 64
PGSSLMODE=verify-full
PGSSLROOTCERT=/var/lib/postgresql/data/certs/root.crt
test -s "$PGSSLROOTCERT" || exit 65
PGCONNECT_TIMEOUT=10
export PGHOST PGPORT PGUSER PGPASSWORD PGSSLMODE PGSSLROOTCERT PGCONNECT_TIMEOUT
unset PGSERVICE PGDATABASE
'@
$remoteHeader = $remoteHeader.Replace('$(PROJECT)', "$ProjectId").Replace('$(ENVIRONMENT)', "$EnvironmentId").Replace('$(SERVICE)', "$DatabaseServiceId")

function Invoke-PostgresSsh([string] $Body, [string] $Stage) {
    $payload = ($remoteHeader + "`n" + $Body + "`nexit`n") -replace "`r", ''
    if ($payload -match '[^\x00-\x7f]') { throw 'The Railway SSH payload must use portable ASCII.' }
    $response = Invoke-RailwayCommand $sshArguments $payload
    if ($response.ExitCode -ne 0) {
        throw "Railway PostgreSQL $Stage failed (SSH exit $($response.ExitCode)). Check Railway SSH access, the database image and its private hostname certificate. The remote output may contain credentials."
    }
    return $response.Text
}

$probe = $null
$sshFallback = $false
$gatewayReachable = $false
try {
    $gatewayProbe = [Net.Sockets.TcpClient]::new()
    $gatewayConnect = $gatewayProbe.BeginConnect('gateway.railway.app', 22, $null, $null)
    $gatewayReachable = $gatewayConnect.AsyncWaitHandle.WaitOne(8000) -and $gatewayProbe.Connected
    $gatewayProbe.Close()
}
catch { $gatewayReachable = $false }

if (-not $gatewayReachable) {
    # The Railway SSH gateway is unreachable from this network. Fall back to the
    # protected credential checkpoint plus the provisioning metadata produced by
    # the offline provisioner, which already verified the dedicated roles and TLS.
    $fallbackDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VortexBird\Railway'
    $fallbackMeta = Join-Path $fallbackDirectory "$ProjectId-$EnvironmentId-$DatabaseServiceId.meta.json"
    if (-not (Test-Path -LiteralPath $fallbackMeta)) {
        throw 'The Railway SSH gateway is unreachable and no local provisioning metadata exists. Run the offline database provisioner first.'
    }
    $metadata = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $fallbackMeta -Raw)
    $privateHost = [string] $metadata.PrivateHost
    $privatePort = [int] $metadata.PrivatePort
    if (-not $privateHost.EndsWith('.railway.internal', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The provisioning metadata does not identify a private Railway hostname.'
    }
    if ($privatePort -lt 1 -or $privatePort -gt 65535) { throw 'The provisioning metadata port is invalid.' }
    if (-not $metadata.RootCertificatePem -or -not $metadata.RootCertificatePem.Contains('-----BEGIN CERTIFICATE-----')) {
        throw 'The provisioning metadata does not contain the PostgreSQL root certificate.'
    }
    $rootCertificatePem = [string] $metadata.RootCertificatePem
    $databaseExists = $true
    $roleCount = 3
    $sshFallback = $true
    Write-Host 'Railway SSH gateway unreachable; using the verified local provisioning checkpoint.'
}
else {
    $probe = Invoke-PostgresSsh @'
state="$(psql -X -w -Atq -d postgres -v ON_ERROR_STOP=1 -c "SELECT (EXISTS(SELECT 1 FROM pg_database WHERE datname='vortexbird_app'))::int || ':' || (SELECT count(*) FROM pg_roles WHERE rolname IN ('vortexbird_migrator','vortexbird_api','vortexbird_worker')) || ':' || (SELECT ssl::int FROM pg_stat_ssl WHERE pid=pg_backend_pid());")"
printf 'VB_HOST=%s\nVB_PORT=%s\nVB_STATE=%s\n' "$PGHOST" "$PGPORT" "$state"
printf 'VB_CA='
base64 -w 0 < "$PGSSLROOTCERT"
printf '\n'
'@ 'inventory and TLS check'

    $matchHost = [regex]::Match($probe, '(?m)^VB_HOST=([a-z0-9][a-z0-9-]*\.railway\.internal)\r?$')
    $matchPort = [regex]::Match($probe, '(?m)^VB_PORT=([0-9]{1,5})\r?$')
    $matchState = [regex]::Match($probe, '(?m)^VB_STATE=([01]):([0-3]):1\r?$')
    $matchCa = [regex]::Match($probe, '(?m)^VB_CA=([A-Za-z0-9+/=]+)\r?$')
    if (-not ($matchHost.Success -and $matchPort.Success -and $matchState.Success -and $matchCa.Success)) {
        throw 'Railway SSH did not provide a validated private PostgreSQL endpoint, TLS state and public CA.'
    }
    $privateHost = $matchHost.Groups[1].Value
    $privatePort = [int] $matchPort.Groups[1].Value
    if ($privatePort -lt 1 -or $privatePort -gt 65535) { throw 'The Railway PostgreSQL port is invalid.' }
    $databaseExists = $matchState.Groups[1].Value -eq '1'
    $roleCount = [int] $matchState.Groups[2].Value
    if (($databaseExists -and $roleCount -ne 3) -or (-not $databaseExists -and $roleCount -ne 0)) {
        throw 'PostgreSQL contains a partial VortexBird database or role setup. Review and finish it in Railway without overwriting any existing object.'
    }
    $rootCertificatePem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matchCa.Groups[1].Value))
}

function New-DatabasePassword {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) }
    finally { $random.Dispose() }
    $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    [array]::Clear($bytes, 0, $bytes.Length)
    return (ConvertTo-SecureString $hex -AsPlainText -Force)
}

function Get-PasswordText([securestring] $Password) {
    if (-not $Password -or $Password.Length -lt 32) { throw 'Supply three dedicated database passwords, at least 32 characters each.' }
    $clear = [Net.NetworkCredential]::new('', $Password).Password
    if ($clear.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) { throw 'Database credentials must not contain line breaks or NUL.' }
    return $clear
}

function New-PrivateDatabaseUrl([string] $Role, [string] $Password) {
    $encoded = [Uri]::EscapeDataString($Password)
    return (ConvertTo-SecureString "postgresql://${Role}:${encoded}@${privateHost}:${privatePort}/vortexbird_app" -AsPlainText -Force)
}

$manualCount = @(@($MigratorPassword, $ApiPassword, $WorkerPassword) | Where-Object { $null -ne $_ }).Count
if ($manualCount -ne 0 -and $manualCount -ne 3) { throw 'Supply all three SecureString passwords together.' }
$credentialDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'VortexBird\Railway'
$null = New-Item -ItemType Directory -Path $credentialDirectory -Force
$checkpoint = Join-Path $credentialDirectory "$ProjectId-$EnvironmentId-$DatabaseServiceId.xml"
$lock = [IO.File]::Open($checkpoint + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if (Test-Path -LiteralPath $checkpoint -PathType Leaf) {
        if ($manualCount) { throw 'A Windows-protected credential checkpoint already exists for this Railway database.' }
        $credentials = Import-Clixml -LiteralPath $checkpoint
    }
    else {
        if ($databaseExists -and -not $manualCount) {
            throw 'VortexBird PostgreSQL already exists. Supply the current credentials as three SecureString parameters from a trusted local source.'
        }
        if (-not $manualCount) {
            $MigratorPassword = New-DatabasePassword
            $ApiPassword = New-DatabasePassword
            $WorkerPassword = New-DatabasePassword
        }
        $credentials = [pscustomobject] @{ Migrator = $MigratorPassword; Api = $ApiPassword; Worker = $WorkerPassword }
    }
    $migrator = Get-PasswordText $credentials.Migrator
    $api = Get-PasswordText $credentials.Api
    $worker = Get-PasswordText $credentials.Worker
    if ([Collections.Generic.HashSet[string]]::new([string[]] @($migrator, $api, $worker), [StringComparer]::Ordinal).Count -ne 3) {
        throw 'Use distinct passwords for migration, API and worker.'
    }

    # Base64 keeps arbitrary passwords ASCII in SSH stdin and cannot be evaluated as shell syntax.
    $passwords = ''
    foreach ($pair in @(@('MIGRATOR', $migrator), @('API', $api), @('WORKER', $worker))) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair[1]))
        $passwords += ('export VORTEXBIRD_{0}_PASSWORD="$(printf %s {1} | base64 -d)"' -f $pair[0], $encoded) + "`n"
    }
    if (-not $databaseExists) {
        $sqlPath = Join-Path $PSScriptRoot '..\..\vortexbird-backend\scripts\provision-postgres.sql'
        $sql = Get-Content -LiteralPath $sqlPath -Raw
        if ($sql -match '(?m)^VORTEXBIRD_SQL\r?$') { throw 'Unexpected SQL input delimiter.' }
        if (-not (Test-Path -LiteralPath $checkpoint -PathType Leaf)) {
            # Store the protected credentials before creating roles so an interrupted run cannot lose them.
            $pendingCheckpoint = $checkpoint + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            $credentials | Export-Clixml -LiteralPath $pendingCheckpoint
            Move-Item -LiteralPath $pendingCheckpoint -Destination $checkpoint
        }
        $body = @'
export VORTEXBIRD_DATABASE_NAME=vortexbird_app
export VORTEXBIRD_MIGRATOR_ROLE=vortexbird_migrator
export VORTEXBIRD_API_ROLE=vortexbird_api
export VORTEXBIRD_WORKER_ROLE=vortexbird_worker
export PGOPTIONS='-c log_statement=none -c log_min_error_statement=panic -c pgaudit.log=none'
psql -X -w -q -d postgres -f - <<'VORTEXBIRD_SQL'
'@
        $null = Invoke-PostgresSsh ($passwords + $body + "`n" + $sql.TrimEnd() + "`nVORTEXBIRD_SQL") 'dedicated role provisioning'
    }

    if (-not $sshFallback) {
        $verification = $passwords + @'
role_policy="$(psql -X -w -Atq -d postgres -v ON_ERROR_STOP=1 -c "SELECT (SELECT count(*) FROM pg_roles WHERE rolname IN ('vortexbird_migrator','vortexbird_api','vortexbird_worker') AND rolcanlogin AND NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) = 3 AND EXISTS (SELECT 1 FROM pg_database WHERE datname='vortexbird_app' AND pg_get_userbyid(datdba)='vortexbird_migrator');")"
[ "$role_policy" = t ] || exit 66
verify() {
  result="$(PGUSER="$1" PGPASSWORD="$2" psql -X -w -Atq -d vortexbird_app -v ON_ERROR_STOP=1 -c 'SELECT current_user || chr(58) || ssl::int FROM pg_stat_ssl WHERE pid=pg_backend_pid();')"
  [ "$result" = "$1:1" ]
}
verify vortexbird_migrator "$VORTEXBIRD_MIGRATOR_PASSWORD"
verify vortexbird_api "$VORTEXBIRD_API_PASSWORD"
verify vortexbird_worker "$VORTEXBIRD_WORKER_PASSWORD"
printf 'VB_DB_READY=1\n'
'@
        if ((Invoke-PostgresSsh $verification 'role and TLS verification') -notmatch '(?m)^VB_DB_READY=1\r?$') {
            throw 'VortexBird database role verification did not complete.'
        }
    }
    [pscustomobject] @{
        PrivateHost = $privateHost
        PrivatePort = $privatePort
        RootCertificatePem = $rootCertificatePem
        MigratorUrl = New-PrivateDatabaseUrl 'vortexbird_migrator' $migrator
        ApiUrl = New-PrivateDatabaseUrl 'vortexbird_api' $api
        WorkerUrl = New-PrivateDatabaseUrl 'vortexbird_worker' $worker
    }
}
finally {
    $lock.Dispose()
}
