$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$realm = Get-Content -LiteralPath (Join-Path $infraRoot 'keycloak/vortexbird-realm.json') -Raw | ConvertFrom-Json
if ($realm.clients[0].directAccessGrantsEnabled -or $realm.clients[0].implicitFlowEnabled) { throw 'Unsafe OIDC client flow.' }
if ($realm.clients[0].attributes.'pkce.code.challenge.method' -ne 'S256') { throw 'PKCE S256 required.' }
if (-not $realm.revokeRefreshToken -or $realm.refreshTokenMaxReuse -ne 0) { throw 'Refresh rotation required.' }
$profile = $realm.components.'org.keycloak.userprofile.UserProfileProvider'[0].config.'kc.user.profile.config'[0] | ConvertFrom-Json
foreach ($claim in 'partner_id','channel_id') {
  $attribute = $profile.attributes | Where-Object { $_.name -eq $claim }
  if (-not $attribute -or $attribute.permissions.edit -contains 'user') { throw "Tenant claim $claim must be admin-managed." }
}
$identityType = $realm.clients[0].protocolMappers | Where-Object { $_.config.'claim.name' -eq 'identity_type' }
if ($identityType.config.'claim.value' -ne 'human') { throw 'Portal identity type must be a server-controlled human claim.' }
Write-Output 'Keycloak security configuration: PASS'
$envFile = Join-Path $infraRoot '.env'
if (-not (Test-Path -LiteralPath $envFile)) { throw 'Run Initialize-Local.ps1 before Compose validation.' }
Push-Location $infraRoot
try {
  docker compose config --quiet
  if ($LASTEXITCODE -ne 0) { throw 'Compose configuration invalid.' }
  Write-Output 'Docker Compose configuration: PASS'
} finally { Pop-Location }
$tf = Get-Command terraform -ErrorAction SilentlyContinue
if ($tf) {
  Push-Location (Join-Path $infraRoot 'terraform')
  try {
    terraform fmt -recursive
    terraform init -backend=false -input=false
    if ($LASTEXITCODE -ne 0) { throw 'Terraform provider initialization failed.' }
    terraform validate
    if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
  } finally { Pop-Location }
} else { Write-Warning 'Terraform not installed; provider/schema validation remains pending.' }
