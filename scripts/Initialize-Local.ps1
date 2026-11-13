param([switch]$Start)
$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $infraRoot '.env'
if (Test-Path -LiteralPath $envFile) { throw '.env already exists. It was not overwritten.' }
function New-LocalSecret { [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) }
$lines = @(
  'POSTGRES_PASSWORD=' + (New-LocalSecret)
  'KEYCLOAK_DB_PASSWORD=' + (New-LocalSecret)
  'KEYCLOAK_ADMIN=local-admin'
  'KEYCLOAK_ADMIN_PASSWORD=' + (New-LocalSecret)
  'DEMO_EMAIL=admin@andesretail.local'
  'DEMO_PASSWORD=' + (New-LocalSecret)
  'DEMO_SIGNING_KEY=' + (New-LocalSecret)
  'DEMO_ENABLED=true'
  'VITE_DEMO_AUTH=true'
  'FRONTEND_PORT=5173'
  'API_PORT=5080'
)
Set-Content -LiteralPath $envFile -Value $lines -Encoding utf8
Write-Output 'Local configuration created in .env. Read DEMO_EMAIL and DEMO_PASSWORD locally to sign in. Do not commit this file.'
if ($Start) {
  Push-Location $infraRoot
  try { docker compose up --build -d; if ($LASTEXITCODE -ne 0) { throw 'Docker Compose failed.' } }
  finally { Pop-Location }
}
