#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$scriptsDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
. (Join-Path $scriptsDirectory 'Native-ProcessIdentity.ps1')
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory 'Start-Native.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Native launcher has syntax errors.' }
foreach ($functionName in @('Quote-Argument', 'Save-State', 'Start-Owned')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    if (-not $definition) { throw "Native launcher function is missing: $functionName" }
    # Load the actual functions without running launcher setup or starting any service.
    . ([scriptblock]::Create($definition.Extent.Text))
}
$loadStatement = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq 'Test-Path -LiteralPath $stateFile'
}, $true)
if (-not $loadStatement) { throw 'The native manifest-loading statement is missing.' }
$loadManifest = [scriptblock]::Create($loadStatement.Extent.Text)

# Reuse the test host itself: no child process, socket, service, or database is created.
$testProcess = Get-Process -Id $PID
$testStartedAt = $testProcess.StartTime.ToUniversalTime()
$testExecutable = $testProcess.Path
if ([string]::IsNullOrWhiteSpace($testExecutable)) { throw 'The test host executable cannot be inspected.' }
$testPort = 55433
$script:listenerRows = @([pscustomobject]@{ LocalPort = $testPort; OwningProcess = $testProcess.Id })
$script:listenerUnavailable = $false
$script:startAttempts = 0
$script:stopAttempts = 0
$script:passed = 0

function Get-NetTCPConnection {
    [CmdletBinding()]
    param([string]$State)
    if ($script:listenerUnavailable) { throw 'Mock listener visibility unavailable.' }
    $script:listenerRows
}
function Start-Process {
    $script:startAttempts++
    throw 'SAFETY: this regression must never start a process.'
}
function Stop-Process {
    $script:stopAttempts++
    throw 'SAFETY: this regression must never stop a process.'
}
function Assert-Condition([bool]$condition, [string]$name) {
    if (-not $condition) { throw "FAILED: $name" }
    $script:passed++
}
function Assert-Rejected([scriptblock]$operation, [string]$pattern, [string]$name) {
    $message = $null
    try { $null = & $operation } catch { $message = $_.Exception.Message }
    Assert-Condition ($message -and $message -match $pattern) $name
}
function Set-TestManifest($startedAt, [int]$processId, [string]$executable) {
    [ordered]@{ name = 'regression'; processId = $processId; startedAt = $startedAt; executable = $executable } |
        ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
    $script:owned = @{}
    # Exercise the launcher's exact ConvertFrom-Json path, including automatic date conversion.
    . $loadManifest
}
function Invoke-TestReuse([string]$executable = $testExecutable) {
    Start-Owned 'regression' $executable @() @{} $runtime $testPort
}

$runtime = Join-Path ([IO.Path]::GetTempPath()) ('vortexbird-process-identity-' + [guid]::NewGuid().ToString('N'))
$stateFile = Join-Path $runtime 'processes.json'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
try {
    foreach ($timestamp in @(
        $testStartedAt.ToString('o'),
        $testStartedAt,
        [DateTimeOffset]$testStartedAt,
        ([DateTimeOffset]$testStartedAt).ToOffset([TimeSpan]::FromHours(-5)).ToString('o')
    )) {
        Assert-Condition (Test-NativeProcessIdentity $testProcess $testProcess.Id $timestamp $testExecutable) 'Exact process identity accepts ISO, DateTime, and DateTimeOffset representations'
    }
    foreach ($timestamp in @(
        $null,
        '',
        'invalid timestamp',
        $testStartedAt.AddTicks(1),
        $testStartedAt.AddSeconds(-1).ToString('o'),
        [DateTime]::SpecifyKind($testStartedAt, [DateTimeKind]::Unspecified)
    )) {
        Assert-Condition (-not (Test-NativeProcessIdentity $testProcess $testProcess.Id $timestamp $testExecutable)) 'Missing, invalid, ambiguous, or mismatched start time is rejected'
    }
    Assert-Condition (-not (Test-NativeProcessIdentity $null $testProcess.Id $testStartedAt $testExecutable)) 'Missing process is rejected'
    Assert-Condition (-not (Test-NativeProcessIdentity $testProcess ($testProcess.Id + 1) $testStartedAt $testExecutable)) 'Different PID is rejected'
    Assert-Condition (-not (Test-NativeProcessIdentity $testProcess $testProcess.Id $testStartedAt ($testExecutable + '.different'))) 'Different executable is rejected'

    Set-TestManifest $testStartedAt.ToString('o') $testProcess.Id $testExecutable
    $loadedDateType = $owned.regression.startedAt.GetType().FullName
    $reused = Invoke-TestReuse
    Assert-Condition ($reused.Id -eq $testProcess.Id) 'Actual Start-Owned reuses the process loaded from the JSON manifest'
    $script:listenerRows = @()
    Assert-Condition ((Invoke-TestReuse).Id -eq $testProcess.Id) 'Owned process without a listener reaches subsequent readiness checks'
    $script:listenerRows = @([pscustomobject]@{ LocalPort = $testPort; OwningProcess = $testProcess.Id })

    foreach ($case in @(
        @{ Name = 'reused PID with older start time'; Start = $testStartedAt.AddSeconds(-1).ToString('o'); Id = $testProcess.Id; Path = $testExecutable },
        @{ Name = 'one-tick difference'; Start = $testStartedAt.AddTicks(1).ToString('o'); Id = $testProcess.Id; Path = $testExecutable },
        @{ Name = 'invalid timestamp'; Start = 'invalid timestamp'; Id = $testProcess.Id; Path = $testExecutable },
        @{ Name = 'different executable path'; Start = $testStartedAt.ToString('o'); Id = $testProcess.Id; Path = $testExecutable + '.different' },
        @{ Name = 'different PID'; Start = $testStartedAt.ToString('o'); Id = [int]::MaxValue; Path = $testExecutable }
    )) {
        Set-TestManifest $case.Start $case.Id $case.Path
        Assert-Rejected { Invoke-TestReuse } 'outside.*ownership' "Start-Owned rejects $($case.Name) while the port is occupied"
    }

    Set-TestManifest $testStartedAt.ToString('o') $testProcess.Id $testExecutable
    Assert-Rejected { Invoke-TestReuse ($testExecutable + '.different') } 'outside.*ownership' 'Requested executable must match the recorded executable'
    $script:listenerRows = @([pscustomobject]@{ LocalPort = $testPort; OwningProcess = $testProcess.Id + 1 })
    Assert-Rejected { Invoke-TestReuse } 'listener outside' 'Different listener PID prevents reuse'
    $script:listenerRows += [pscustomobject]@{ LocalPort = $testPort; OwningProcess = $testProcess.Id }
    Assert-Rejected { Invoke-TestReuse } 'listener outside' 'One matching listener cannot hide another listener with a different owner'
    $script:listenerUnavailable = $true
    Assert-Rejected { Invoke-TestReuse } 'unknown, not free' 'Unavailable listener visibility prevents reuse'
    $script:listenerUnavailable = $false

    Assert-Condition ($script:startAttempts -eq 0 -and $script:stopAttempts -eq 0) 'No process was started or stopped'
    [pscustomobject]@{
        passed = $script:passed
        failed = 0
        serviceStarts = $script:startAttempts
        processStops = $script:stopAttempts
        databaseConnections = 0
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        manifestDateType = $loadedDateType
        scope = 'Native process identity and actual Start-Owned manifest reuse regression'
    } | ConvertTo-Json
} finally {
    # Delete only the two exact paths created by this test; never recurse into a runtime directory.
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile }
    [IO.Directory]::Delete($runtime)
}
