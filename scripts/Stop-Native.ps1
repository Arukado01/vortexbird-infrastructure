#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
$workspaceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stateFile = Join-Path $workspaceRoot '.work/native-runtime/processes.json'
$failures = @()
if (Test-Path -LiteralPath $stateFile) {
    $records = @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json)
    foreach ($name in @('frontend','api','postgres')) {
        foreach ($record in $records | Where-Object name -eq $name) {
            try {
                $process = Get-Process -Id $record.processId -ErrorAction SilentlyContinue
                if (-not $process) { continue }
                if (-not (Test-NativeProcessIdentity $process $record.processId $record.startedAt $record.executable)) { throw "Cannot verify the recorded process for $name. Nothing was stopped for this service." }
                if ($name -eq 'postgres') {
                    & (Join-Path (Split-Path $record.executable -Parent) 'pg_ctl.exe') -D (Join-Path $workspaceRoot '.work/native-runtime/postgres') -m fast -w stop
                    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL clean stop failed; data was preserved.' }
                } else { Stop-Process -Id $process.Id -ErrorAction Stop; $process.WaitForExit(10000) | Out-Null }
            } catch { $failures += $_.Exception.Message }
        }
    }
    if ($failures.Count -eq 0) { Remove-Item -LiteralPath $stateFile }
}
foreach ($script in @('Stop-Native-Messaging.ps1','Stop-KeycloakNative.ps1')) {
    try { & (Join-Path $PSScriptRoot $script) } catch { $failures += $_.Exception.Message }
}
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
Write-Output 'Native services stopped. PostgreSQL data, identity data and configuration were preserved.'
