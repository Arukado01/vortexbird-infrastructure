#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Apply, [switch]$ResetPasswords, [string]$EmailDomain = 'prueba.com', [string]$RemoveFrom)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$region = 'us-east-2'
$poolId = 'us-east-2_nLop817zD'
$profileName = 'btc-deploy'
$awsOptions = @('--profile', $profileName, '--region', $region, '--output', 'json', '--no-cli-pager')

function Invoke-Aws {
    param([string[]]$Arguments, [string]$Resource)
    $output = & aws @Arguments @awsOptions 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AWS $($Arguments[0]) failed for ${Resource}: $(($output | ForEach-Object { $_.ToString() }) -join ' ')" }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

# Role -> (friendly login local-part, simple display name)
$accounts = [ordered]@{
    'SUPER_ADMIN'         = @{ local = 'superadmin';    display = 'superAdminPrueba' }
    'ADMIN'               = @{ local = 'admin';         display = 'adminPrueba' }
    'ARCHITECT'           = @{ local = 'arquitecto';    display = 'arquitectoPrueba' }
    'INTEGRATION_MANAGER' = @{ local = 'gestor';        display = 'gestorIntegracionesPrueba' }
    'OPERATIONS'          = @{ local = 'operaciones';   display = 'operacionesPrueba' }
    'SECURITY_AUDITOR'    = @{ local = 'auditor';       display = 'auditorPrueba' }
    'PARTNER_ADMIN'       = @{ local = 'adminpartner';  display = 'adminPartnerPrueba' }
    'PARTNER_USER'        = @{ local = 'usuariopartner'; display = 'usuarioPartnerPrueba' }
    'VIEWER'              = @{ local = 'visualizador';  display = 'visualizadorPrueba' }
}

$batch = $null
$pilotAccounts = @()
foreach ($role in $accounts.Keys) {
    $group = Invoke-Aws -Arguments @('cognito-idp', 'list-users-in-group', '--user-pool-id', $poolId, '--group-name', $role) -Resource $role
    $user = @($group.Users) | Select-Object -First 1
    if (@($group.Users).Count -ne 1) { throw "Cognito role $role must contain exactly one pilot user." }
    $attributes = @{}
    foreach ($attribute in $user.Attributes) { $attributes[$attribute.Name] = $attribute.Value }
    $batch = $attributes['custom:pilot_batch']
    $pilotAccounts += [pscustomobject]@{ role = $role; subject = $attributes['sub']; email = $attributes['email'] }
}
if ($batch -cnotmatch '^[a-f0-9]{32}$') { throw 'Pilot batch attribute not found in the Cognito groups.' }
Write-Host "Pilot batch: $batch"

if (-not $Apply) { Write-Host 'Dry run complete (use -Apply to create the users).'; return }

if ($RemoveFrom) {
    $previous = ConvertFrom-Json (Get-Content $RemoveFrom -Raw)
    foreach ($old in $previous) {
        if ($PSCmdlet.ShouldProcess($old.email, "Delete superseded Cognito test user")) {
            $null = Invoke-Aws -Arguments @('cognito-idp', 'admin-delete-user', '--user-pool-id', $poolId, '--username', $old.email) -Resource $old.email
            Write-Host "DELETED $($old.email)"
        }
    }
}

function New-AccountPassword {
    $lower = 'abcdefghijkmnopqrstuvwxyz'; $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $digits = '23456789'; $symbols = '!#$%&*+-=?@'
    $random = [System.Random]::new()
    $chars = @($lower[$random.Next($lower.Length)], $upper[$random.Next($upper.Length)], $digits[$random.Next($digits.Length)], $symbols[$random.Next($symbols.Length)])
    $pool = $lower + $upper + $digits + $symbols
    1..12 | ForEach-Object { $chars += $pool[$random.Next($pool.Length)] }
    # Fisher-Yates so the leading classes are not predictable.
    for ($i = $chars.Length - 1; $i -gt 0; $i--) { $j = $random.Next($i + 1); ($chars[$i], $chars[$j]) = ($chars[$j], $chars[$i]) }
    return -join $chars
}

$results = @()
foreach ($role in $accounts.Keys) {
    $spec = $accounts[$role]
    $email = "$($spec.local)@$EmailDomain"
    $existing = $null
    try { $existing = Invoke-Aws -Arguments @('cognito-idp', 'admin-get-user', '--user-pool-id', $poolId, '--username', $email) -Resource $email } catch { }
    if ($existing) {
        Write-Host "EXISTS  $email"
    } elseif ($PSCmdlet.ShouldProcess($email, "Create Cognito test user for role $role")) {
        $null = Invoke-Aws -Arguments @('cognito-idp', 'admin-create-user', '--user-pool-id', $poolId, '--username', $email,
            '--user-attributes', "Name=email,Value=$email", 'Name=email_verified,Value=true',
            "Name=custom:pilot_role,Value=$role", "Name=custom:pilot_batch,Value=$batch",
            '--message-action', 'SUPPRESS') -Resource $email
        Write-Host "CREATED $email"
    }
    $user = Invoke-Aws -Arguments @('cognito-idp', 'admin-get-user', '--user-pool-id', $poolId, '--username', $email) -Resource $email
    $attributes = @{}
    foreach ($attribute in $user.UserAttributes) { $attributes[$attribute.Name] = $attribute.Value }
    if ($user.Enabled -ne $true) { throw "Test account $email is disabled." }
    $password = $null
    if ($user.UserStatus -eq 'FORCE_CHANGE_PASSWORD' -or $ResetPasswords) {
        $password = New-AccountPassword
        $null = Invoke-Aws -Arguments @('cognito-idp', 'admin-set-user-password', '--user-pool-id', $poolId,
            '--username', $email, '--password', $password, '--permanent') -Resource "$email password"
    }
    $results += [pscustomobject]@{ role = $role; subject = $attributes['sub']; email = $email; displayName = $spec.display; password = $password }
}

$outDir = Join-Path (Join-Path (Join-Path $PSScriptRoot '..' ) '..') 'qa'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$results | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $outDir 'usuarios-prueba-cognito.json')
Write-Host "Test accounts ready: $(@($results).Count). Manifest data in qa/usuarios-prueba-cognito.json"
