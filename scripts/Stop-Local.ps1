#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $infraRoot '.env'
$composeFile = Join-Path $infraRoot 'compose.yaml'
$dockerCommand = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dockerCommand) { throw 'Docker no esta disponible en esta sesion.' }
if (-not (Test-Path -LiteralPath $envFile)) { throw 'Falta la configuracion local .env. No se regenero ni se elimino ningun dato.' }
Push-Location $infraRoot
try {
    & $dockerCommand.Source compose --env-file $envFile --file $composeFile stop --timeout 30
    if ($LASTEXITCODE -ne 0) { throw 'Docker no pudo detener todos los servicios. Revisa su estado desde tu sesion de Docker Desktop.' }
    Write-Host 'Servicios locales detenidos. Se conservan contenedores, volumenes, datos y configuracion.'
} finally { Pop-Location }
