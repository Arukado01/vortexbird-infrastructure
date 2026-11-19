#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile = 'btc-deploy', [string]$OutFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$region = 'us-east-2'
$poolId = 'us-east-2_nLop817zD'
$awsOptions = @('--profile', $Profile, '--region', $region, '--output', 'json', '--no-cli-pager')
$roles = @('SUPER_ADMIN', 'ADMIN', 'ARCHITECT', 'INTEGRATION_MANAGER', 'OPERATIONS', 'SECURITY_AUDITOR', 'PARTNER_ADMIN', 'PARTNER_USER', 'VIEWER')

function Invoke-Aws {
    param([string[]]$Arguments, [string]$Resource)
    $output = & aws @Arguments @awsOptions 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AWS $($Arguments[0]) failed for ${Resource}: $(($output | ForEach-Object { $_.ToString() }) -join ' ')" }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

$batch = $null
$accounts = @()
foreach ($role in $roles) {
    $group = Invoke-Aws -Arguments @('cognito-idp', 'list-users-in-group', '--user-pool-id', $poolId, '--group-name', $role) -Resource $role
    $user = @($group.Users) | Select-Object -First 1
    if (@($group.Users).Count -ne 1) { throw "Cognito role $role must contain exactly one pilot user." }
    $attributes = @{}
    foreach ($attribute in $user.Attributes) { $attributes[$attribute.Name] = $attribute.Value }
    $batch = $attributes['custom:pilot_batch']
    $accounts += [pscustomobject]@{ role = $role; subject = $attributes['sub']; email = $attributes['email'] }
}

$testsPath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'qa' | ForEach-Object { Join-Path $_ 'usuarios-prueba-cognito.json' }
$tests = ConvertFrom-Json (Get-Content $testsPath -Raw)
# Deterministic logins of superseded test accounts, so the deployment job relinks each DB identity
# (keeping its id, role grant and tenant scope) instead of creating a parallel row.
$superseded = @{
    'SUPER_ADMIN'         = 'superadminprueba@pilot.vortexbird.invalid'
    'ADMIN'               = 'adminprueba@pilot.vortexbird.invalid'
    'ARCHITECT'           = 'arquitectoprueba@pilot.vortexbird.invalid'
    'INTEGRATION_MANAGER' = 'gestorintegracionesprueba@pilot.vortexbird.invalid'
    'OPERATIONS'          = 'operacionesprueba@pilot.vortexbird.invalid'
    'SECURITY_AUDITOR'    = 'auditorprueba@pilot.vortexbird.invalid'
    'PARTNER_ADMIN'       = 'adminpartnerprueba@pilot.vortexbird.invalid'
    'PARTNER_USER'        = 'usuariopartnerprueba@pilot.vortexbird.invalid'
    'VIEWER'              = 'visualizadorprueba@pilot.vortexbird.invalid'
}
$testAccounts = @($tests | ForEach-Object {
    $previous = $superseded[$_.role]
    if ($previous -and $previous -cne $_.email) { [pscustomobject]@{ role = $_.role; subject = $_.subject; email = $_.email; displayName = $_.displayName; replaces = $previous } }
    else { [pscustomobject]@{ role = $_.role; subject = $_.subject; email = $_.email; displayName = $_.displayName } }
})

$manifest = [pscustomobject]@{
    issuer       = "https://cognito-idp.$region.amazonaws.com/$poolId"
    batch        = $batch
    accounts     = $accounts
    testAccounts = $testAccounts
}
$json = ConvertTo-Json -InputObject $manifest -Depth 6
$bytes = [Text.Encoding]::UTF8.GetByteCount($json)
if (-not $OutFile) {
    $workRoot = Join-Path (Join-Path $PSScriptRoot '..') '..'
    $OutFile = Join-Path (Join-Path $workRoot '.work') 'pilot-manifest-v2.json'
}
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
[IO.File]::WriteAllText($OutFile, $json, [Text.UTF8Encoding]::new($false))
Write-Host "Manifest v2 written to $OutFile ($bytes bytes); batch $batch; $($testAccounts.Count) test accounts."
