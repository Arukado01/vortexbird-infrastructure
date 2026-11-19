#requires -Version 7.4
# Drive the real continuation script through a failing launcher. No service or socket is needed.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureName = 'vortexbird-evidence-' + [guid]::NewGuid().ToString('N')
$fixture = Join-Path $temporary $fixtureName
try {
    $scripts = New-Item -ItemType Directory -Path (Join-Path $fixture 'vortexbird-infrastructure/scripts') -Force
    $javaBin = New-Item -ItemType Directory -Path (Join-Path $fixture 'jdk/bin') -Force
    New-Item -ItemType File -Path (Join-Path $javaBin 'java.exe') | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'jdk/release') -Value 'JAVA_VERSION="25.0.1"'
    $launcher = Join-Path $fixture 'Continuar-VortexBird.ps1'
    Copy-Item -LiteralPath (Join-Path $workspace 'Continuar-VortexBird.ps1') -Destination $launcher
    @'
param($JavaHome, $PostgresPort)
'{"configuredNativePorts":{},"listeners":{"status":"fixture"},"excludedTcpPorts":[{"status":"fixture"}]}'
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Diagnose-Local.ps1')
    @'
param($JavaHome, $PostgresPort, $HealthTimeoutSeconds, [switch]$OidcOnly, [switch]$ValidateOnly, [scriptblock]$OnVerified)
if ($ValidateOnly) { return }
& $OnVerified 'verified fixture step'
throw 'simulated failure in the next step'
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Start-Native.ps1')
    @'
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'review-attempts.txt') -Value 'attempt'
[pscustomobject]@{status='blocked';summaryPath='fixture/summary.json';blockedStages=@('fixture inventory')}
'@ | Set-Content -LiteralPath (Join-Path $scripts 'New-EcsFirstReview.ps1')
    $attempts = Join-Path $scripts 'review-attempts.txt'
    $javaHomePath = Join-Path $fixture 'jdk'
    $runtime = Join-Path $fixture '.work/native-runtime'
    & $launcher -JavaHome $javaHomePath -ReviewAwsPlan -ValidateOnly | Out-Null
    if ((Test-Path -LiteralPath $runtime) -or (Test-Path -LiteralPath $attempts)) { throw 'Validation started a review or wrote runtime evidence.' }
    $summary = Join-Path $runtime 'continuation-result.json'
    foreach ($run in 1..2) {
        $expectedFailure = $false
        try { & $launcher -JavaHome $javaHomePath -ReviewAwsPlan | Out-Null }
        catch { $expectedFailure = $_.Exception.Message -like '*simulated failure in the next step*' }
        if (!$expectedFailure) { throw 'The launcher did not propagate the expected failure.' }
        $result = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
        if ($result.status -ne 'failed' -or $result.completeAcceptanceGate -or $result.checks.Count -ne 1 -or
            $result.checks[0].name -ne 'verified fixture step' -or $result.checks[0].status -ne 'passed' -or
            $result.liveTests.status -ne 'not-run' -or $result.businessTests.status -ne 'not-run' -or
            $result.awsPlanReview.status -ne 'blocked' -or $result.awsPlanReview.summaryPath -ne 'fixture/summary.json' -or
            @(Get-Content -LiteralPath $attempts).Count -ne $run) {
            throw 'The partial result did not retain precisely the completed step.'
        }
        if ($run -eq 1) { $firstHash = (Get-FileHash -LiteralPath $summary).Hash }
    }
    $archived = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'history') -Recurse -File -Filter 'continuation-result.json')
    if ($archived.Count -ne 1 -or (Get-FileHash -LiteralPath $archived[0].FullName).Hash -ne $firstHash) {
        throw 'The prior run was not preserved byte-for-byte.'
    }
    Write-Output 'PASS: validation is read-only, a later failure retains verified steps, and rerunning archives the prior report.'
} finally {
    if ([IO.Path]::GetFullPath($fixture) -eq [IO.Path]::Combine($temporary, $fixtureName) -and [IO.Directory]::Exists($fixture)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
