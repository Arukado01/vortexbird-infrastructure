#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(30, 900)]
    [int]$HealthTimeoutSeconds = 180,
    [switch]$SeedDemo
)

$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $infraRoot '.env'
$composeFile = Join-Path $infraRoot 'compose.yaml'
$dockerCommand = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dockerCommand) { throw 'Docker no esta disponible. Instala/inicia Docker Desktop y vuelve a ejecutar este archivo desde tu sesion.' }

Push-Location $infraRoot
try {
    Write-Host 'Comprobando Docker Desktop...'
    try {
        $daemonResult = & $dockerCommand.Source info --format '{{.ServerVersion}}' 2>&1
        $daemonExitCode = $LASTEXITCODE
    } catch {
        $daemonResult = $_.Exception.Message
        $daemonExitCode = 1
    }
    if ($daemonExitCode -ne 0) {
        $daemonDetail = ($daemonResult | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($daemonDetail)) { $daemonDetail = 'Docker no devolvio detalles del fallo.' }
        throw "Docker encontrado en '$($dockerCommand.Source)', pero fallo la comprobacion del motor (codigo $daemonExitCode). Error original: $daemonDetail"
    }
    $daemonResult = $null
    & $dockerCommand.Source compose version --short
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 no esta disponible. Revisa la instalacion de Docker Desktop.' }

    foreach ($repository in 'vortexbird-backend', 'vortexbird-frontend') {
        if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $infraRoot -Parent) "$repository/Dockerfile"))) {
            throw "Falta el Dockerfile del repositorio hermano $repository. No se inicio ningun servicio."
        }
    }
    if (-not (Test-Path -LiteralPath $envFile)) {
        & (Join-Path $PSScriptRoot 'Initialize-Local.ps1')
    } else {
        Write-Host 'Se reutiliza la configuracion local existente sin reemplazarla.'
    }

    # Resolve exactly the same explicit file/env inputs for validation and startup.
    # The JSON can contain infrastructure secrets: retain it only in memory and
    # never print, log, export or forward it to Write-Output/Write-Host.
    $composeArguments = @('compose', '--env-file', $envFile, '--file', $composeFile)
    & $dockerCommand.Source @composeArguments config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose rechazo la configuracion. Corrige las variables indicadas; no se regenero .env.' }
    $resolvedJson = & $dockerCommand.Source @composeArguments config --format json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer la configuracion resuelta de Compose sin mostrar secretos.' }
    try { $resolved = ($resolvedJson -join "`n") | ConvertFrom-Json }
    catch { throw 'Docker Compose devolvio una configuracion JSON no valida. No se inicio la plataforma.' }
    $resolvedJson = $null

    $apiBinding = @($resolved.services.backend.ports | Where-Object { $_.target -eq 8080 })
    $portalBinding = @($resolved.services.frontend.ports | Where-Object { $_.target -eq 8080 })
    foreach ($binding in @($apiBinding) + @($portalBinding)) {
        if ($binding.host_ip -ne '127.0.0.1' -or [string]$binding.published -notmatch '^\d+$') {
            throw 'El launcher solo admite puertos locales ligados a 127.0.0.1. Revisa compose.yaml.'
        }
    }
    if ($apiBinding.Count -ne 1 -or $portalBinding.Count -ne 1) { throw 'No se pudo determinar un unico puerto local para API y portal.' }
    $apiUrl = 'http://localhost:' + $apiBinding[0].published
    $portalUrl = 'http://localhost:' + $portalBinding[0].published
    $keycloakUrl = [string]$resolved.services.frontend.environment.VITE_KEYCLOAK_URL
    $demoEnabled = [string]$resolved.services.backend.environment.Authentication__DemoEnabled -eq 'true'
    $portalDemoEnabled = [string]$resolved.services.frontend.environment.VITE_DEMO_AUTH -eq 'true'
    $demoEmail = [string]$resolved.services.backend.environment.Demo__Email
    $demoPassword = [string]$resolved.services.backend.environment.Demo__Password
    $resolved = $null
    if ($demoEnabled -ne $portalDemoEnabled) { throw 'DEMO_ENABLED y VITE_DEMO_AUTH deben coincidir. No se modifico tu configuracion.' }

    Write-Host 'Construyendo e iniciando la plataforma. La primera descarga puede tardar varios minutos...'
    & $dockerCommand.Source @composeArguments up --build -d
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Compose no completo el arranque. Revisa el error anterior y docker compose ps. Los datos/volumenes se conservaron; no se declara la plataforma lista.'
    }

    Write-Host "Esperando API y portal (hasta $HealthTimeoutSeconds segundos)..."
    $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
    $apiReady = $false
    $portalReady = $false
    do {
        try {
            $apiState = Invoke-RestMethod -Uri "$apiUrl/health/ready" -TimeoutSec 3 -MaximumRedirection 0
            $apiReady = $apiState.status -eq 'ready'
        } catch { $apiReady = $false }
        try {
            $portalState = Invoke-WebRequest -Uri "$portalUrl/health" -TimeoutSec 3 -MaximumRedirection 0 -UseBasicParsing
            $portalContent = if ($portalState.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($portalState.Content) } else { [string]$portalState.Content }
            $portalReady = $portalState.StatusCode -eq 200 -and $portalContent.Trim() -eq 'ok'
        } catch { $portalReady = $false }
        if ($apiReady -and $portalReady) { break }
        if ([DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 2 }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not ($apiReady -and $portalReady)) {
        throw "Timeout de salud: API=$apiReady, portal=$portalReady. Revisa docker compose ps y los logs de backend/frontend desde $infraRoot. No se borraron datos ni se muestran credenciales como si el arranque hubiera funcionado."
    }

    # Check the seeded account too; never display the returned JWT or response.
    if ($demoEnabled) {
        try {
            $loginBody = @{ email = $demoEmail; password = $demoPassword } | ConvertTo-Json -Compress
            $login = Invoke-RestMethod -Method Post -Uri "$portalUrl/api/v1/auth/demo-login" -ContentType 'application/json' -Body $loginBody -TimeoutSec 10 -MaximumRedirection 0
            if ([string]::IsNullOrWhiteSpace($login.accessToken)) { throw 'Token ausente.' }
        } catch { throw 'API y portal responden, pero no se pudo autenticar la cuenta de demo mediante el portal. Revisa el seed y la configuracion local. No se muestran credenciales como verificadas.' }
        finally { $loginBody = $null }
        if ($SeedDemo) {
            $seedPath = Join-Path (Split-Path $infraRoot -Parent) 'vortexbird-backend/scripts/Seed-Demo.ps1'
            $oldDemoEmail = [Environment]::GetEnvironmentVariable('Demo__Email', 'Process')
            $oldDemoPassword = [Environment]::GetEnvironmentVariable('Demo__Password', 'Process')
            try {
                $existing = Invoke-RestMethod -Uri "$apiUrl/api/v1/orders?page=1&pageSize=1" -Headers @{ Authorization = "Bearer $($login.accessToken)" } -TimeoutSec 15 -MaximumRedirection 0
                if ($null -eq $existing.totalCount) { throw 'La API no devolvio el total de pedidos.' }
                if ($existing.totalCount -eq 0) {
                    if (-not (Test-Path -LiteralPath $seedPath)) { throw 'Falta el script de pedidos de demostracion.' }
                    [Environment]::SetEnvironmentVariable('Demo__Email', $demoEmail, 'Process')
                    [Environment]::SetEnvironmentVariable('Demo__Password', $demoPassword, 'Process')
                    Write-Host 'Preparando 18 pedidos de demostracion mediante la API...'
                    & $seedPath -BaseUrl $apiUrl -Count 18
                    $after = Invoke-RestMethod -Uri "$apiUrl/api/v1/orders?page=1&pageSize=1" -Headers @{ Authorization = "Bearer $($login.accessToken)" } -TimeoutSec 15 -MaximumRedirection 0
                    if ($after.totalCount -lt 18) { throw 'No se verificaron los 18 pedidos esperados.' }
                    Write-Host 'Pedidos creados y verificados. El worker actualizara sus estados y el dashboard.'
                } else {
                    Write-Host "Se conservan los $($existing.totalCount) pedidos existentes; no se agregan duplicados."
                }
            } catch {
                throw 'El login funciona, pero fallo la preparacion/verificacion de pedidos. Los pedidos ya creados se conservaron. Revisa la API antes de volver a sembrar datos.'
            } finally {
                [Environment]::SetEnvironmentVariable('Demo__Email', $oldDemoEmail, 'Process')
                [Environment]::SetEnvironmentVariable('Demo__Password', $oldDemoPassword, 'Process')
                $login = $null
            }
        }
        $login = $null
    }

    Write-Host ''
    Write-Host 'API y portal: HEALTH PASS' -ForegroundColor Green
    Write-Host "Portal: $portalUrl"
    Write-Host "API:    $apiUrl"
    Write-Host "Salud:  $apiUrl/health/ready"
    Write-Host "Keycloak (no comprobado por este launcher): $keycloakUrl"
    if ($demoEnabled) {
        Write-Host 'Acceso de demo: LOGIN PASS' -ForegroundColor Green
        Write-Host "DEMO_EMAIL=$demoEmail"
        Write-Host "DEMO_PASSWORD=$demoPassword"
        Write-Host 'Estas credenciales son locales. No compartas la salida ni el archivo .env.'
    } else {
        Write-Host 'Se conserva el modo OIDC configurado. No se habilito autenticacion de demo.'
    }
    Write-Host 'Para detener sin borrar datos: scripts/Stop-Local.ps1'
} finally {
    $resolvedJson = $null
    $resolved = $null
    $login = $null
    $demoPassword = $null
    Pop-Location
}
