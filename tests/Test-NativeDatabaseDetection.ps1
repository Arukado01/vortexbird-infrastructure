#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Start-Native.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Native launcher has syntax errors.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-DatabaseExistsResult' }, $true)
if (-not $definition) { throw 'Database detection function is missing.' }
# Load only this pure file-reading function: never execute the launcher or connect to PostgreSQL.
. ([scriptblock]::Create($definition.Extent.Text))
$temporaryFile = [IO.Path]::GetTempFileName()
$passed = 0
try {
    foreach ($case in @(
        @{ Name = 'empty stdout means database absent'; Text = ''; Expected = $false },
        @{ Name = 'whitespace stdout means database absent'; Text = "`r`n "; Expected = $false },
        @{ Name = 'single row means database exists'; Text = "1`r`n"; Expected = $true }
    )) {
        [IO.File]::WriteAllText($temporaryFile, $case.Text)
        $actual = Test-DatabaseExistsResult $temporaryFile
        if ($actual -isnot [bool] -or $actual -ne $case.Expected) { throw "FAILED: $($case.Name)" }
        $passed++
    }
    foreach ($invalid in @('unexpected output', "1`n1")) {
        [IO.File]::WriteAllText($temporaryFile, $invalid)
        $rejected = $false
        try { $null = Test-DatabaseExistsResult $temporaryFile } catch { $rejected = $true }
        if (-not $rejected) { throw 'Unexpected SQL output must not trigger database creation.' }
        $passed++
    }
    [pscustomobject]@{ passed = $passed; failed = 0; serviceStarts = 0; databaseConnections = 0; scope = 'Native PostgreSQL database existence parsing regression' } | ConvertTo-Json
} finally {
    Remove-Item -LiteralPath $temporaryFile
}
