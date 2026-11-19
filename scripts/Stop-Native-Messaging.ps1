#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
$workspaceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stateFile = Join-Path $workspaceRoot '.work/native-messaging/process.json'
if (-not (Test-Path -LiteralPath $stateFile)) { Write-Output 'No owned native messaging process is recorded.'; return }
$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$process = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
if ($process) {
    if (-not (Test-NativeProcessIdentity $process $state.processId $state.startedAt $state.executable)) { throw 'The recorded PID belongs to a different process. Nothing was stopped.' }
    Stop-Process -Id $process.Id -ErrorAction Stop
    $process.WaitForExit(10000) | Out-Null
}
Remove-Item -LiteralPath $stateFile
Write-Output 'Native messaging stopped; PostgreSQL and other processes were preserved. ElasticMQ messages are local and ephemeral.'
