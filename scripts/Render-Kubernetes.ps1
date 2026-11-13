param([Parameter(Mandatory)][string]$ValuesFile)
$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$values = Get-Content -LiteralPath $ValuesFile -Raw | ConvertFrom-Json -AsHashtable
$required = 'BACKEND_IMAGE','FRONTEND_IMAGE','BACKEND_ROLE_ARN','KEYCLOAK_ROLE_ARN','APPLICATION_SECRET_ARN','KEYCLOAK_SECRET_ARN','QUEUE_URL','APP_HOST','API_HOST','AUTH_HOST','ACM_CERTIFICATE_ARN','WAF_ARN'
foreach ($key in $required) { if ([string]::IsNullOrWhiteSpace($values[$key])) { throw "Missing $key" } }
foreach ($key in 'BACKEND_IMAGE','FRONTEND_IMAGE') { if ($values[$key] -notmatch '@sha256:[a-f0-9]{64}$') { throw "$key must use an immutable SHA256 image digest." } }
foreach ($key in 'APP_HOST','API_HOST','AUTH_HOST') { if ($values[$key] -notmatch '^[a-zA-Z0-9.-]+$' -or $values[$key] -match 'example|tudominio|localhost') { throw "$key must be a verified owned DNS hostname." } }
foreach ($key in $values.Keys) { if ([string]$values[$key] -match '[\r\n"\x27]') { throw "Unsafe multiline/quoted value in $key" } }
$destination = Join-Path $infraRoot 'rendered'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($source in Get-ChildItem -LiteralPath (Join-Path $infraRoot 'kubernetes') -Filter '*.yaml') {
  $rendered = Get-Content -LiteralPath $source.FullName -Raw
  foreach ($key in $required) { $rendered = $rendered.Replace(('${' + $key + '}'), [string]$values[$key]) }
  if ($rendered -match '\$\{[A-Z_]+\}') { throw "Unresolved placeholder in $($source.Name)" }
  Set-Content -LiteralPath (Join-Path $destination $source.Name) -Value $rendered -Encoding utf8
}
Write-Output 'Manifests rendered. No cluster changes made. Review with kubectl diff -f rendered after approval.'
