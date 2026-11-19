#requires -Version 7.4
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
$workspaceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$manifestPath = Join-Path $workspaceRoot '.work/native-runtime/keycloak-process.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'No tracked native Keycloak process.'; return }
$identity = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$process = Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
if (-not $process) { Write-Output 'The tracked Keycloak process is no longer running.'; return }
if (-not (Test-NativeProcessIdentity $process $identity.pid $identity.startTimeUtc $identity.executable)) {
    throw 'Process identity differs from the recorded Keycloak PID/start time/executable. Nothing was stopped.'
}
if ($ValidateOnly) { Write-Output 'Tracked Keycloak process identity validated; no process was stopped.'; return }
Stop-Process -InputObject $process -ErrorAction Stop
Write-Output 'Stopped the tracked native Keycloak process; realm data, import files and .env were preserved.'
