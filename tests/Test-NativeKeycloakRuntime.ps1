#requires -Version 7.4
[CmdletBinding()]
param([string]$ArchivePath, [string]$JavaHome)
$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
. (Join-Path $infra 'scripts/Native-KeycloakRuntime.ps1')
. (Join-Path $infra 'scripts/Native-ProcessIdentity.ps1')
if (-not $ArchivePath) { $ArchivePath = Join-Path (Split-Path $infra -Parent) '.work/closure-keycloak.zip' }
if (-not [IO.File]::Exists($ArchivePath)) { throw 'Supply the local Keycloak 26.4.0 distribution ZIP with -ArchivePath.' }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureName = 'vortexbird-keycloak-test-' + [guid]::NewGuid().ToString('N')
$workspace = Join-Path $temporaryRoot $fixtureName
$root = Join-Path $workspace '.work/validation-20261117/keycloak-26.4.0'
$build = Join-Path $root 'lib/quarkus'
$manifest = Join-Path $workspace 'manifest.json'
$archive = Join-Path $workspace '.work/closure-keycloak.zip'
$marker = Join-Path $build '.vortexbird-repair-pending'
$version = Join-Path $root 'version.txt'
$initialVersion = 'Keycloak - Version 26.4.0'
$script:passed = 0
$script:javaRows = @()
$script:cimUnavailable = $false
function Get-CimInstance {
    [CmdletBinding()] param([string]$ClassName, [string]$Filter)
    if ($script:cimUnavailable) { throw 'Simulated unavailability.' }
    $script:javaRows
}
function Assert-Condition([bool]$ok, [string]$name) {
    if (-not $ok) { throw "FAILED: $name" }
    $script:passed++
}
function Assert-Throws([scriptblock]$operation, [string]$pattern) {
    $message = ''
    try { $null = & $operation } catch { $message = $_.Exception.Message }
    Assert-Condition ($message -match $pattern) "Expected '$pattern'; received '$message'"
}
function Invoke-Recovery { Initialize-NativeKeycloakRuntime $workspace $root $manifest }
function Invoke-OptimizedStartDryRun([string]$runner, [string]$allowHttp = 'true') {
    $start = [Diagnostics.ProcessStartInfo]::new($java)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $root
    $start.RedirectStandardOutput = $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -match '^(KC_|KCRAW_|QUARKUS_|JAVA_TOOL_OPTIONS$|JDK_JAVA_OPTIONS$|_JAVA_OPTIONS$)') { [void]$start.Environment.Remove($key) }
    }
    $start.Environment['KC_DRY_RUN'] = 'true'
    $start.Environment['KC_HTTP_ENABLED'] = $allowHttp
    $start.Environment['KC_HOSTNAME'] = 'http://localhost:18080'
    $start.Environment['KC_CACHE'] = 'local'
    foreach ($arg in (@(Get-NativeKeycloakJavaOptions $root) + @('-cp',$runner,'io.quarkus.bootstrap.runner.QuarkusEntryPoint','start','--optimized','--import-realm'))) {
        $start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(45000)) { $process.Kill($true); throw 'Optimized CLI dry run timed out.' }
        return @{ code = $process.ExitCode; output = $out.GetAwaiter().GetResult() + $err.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
try {
    [void][IO.Directory]::CreateDirectory($build)
    [IO.File]::WriteAllText($version, $initialVersion)
    $emptyJar = Join-Path $build 'transformed-bytecode.jar'
    [IO.Compression.ZipFile]::Open($emptyJar, [IO.Compression.ZipArchiveMode]::Create).Dispose()
    [IO.File]::WriteAllText($archive, 'wrong source archive')
    Assert-Throws { Invoke-Recovery } 'unexpected SHA-256'
    Assert-Throws { Resolve-NativeKeycloakRuntime $workspace $root $manifest 'unused' -ValidateOnly } 'unexpected SHA-256'
    [IO.File]::Copy($ArchivePath, $archive, $true)
    $message = Initialize-NativeKeycloakRuntime $workspace $root $manifest -ValidateOnly
    Assert-Condition ($message -match 'recoverable' -and (Get-ChildItem $build -Force).Count -eq 1) 'Read-only preflight reported recovery and left the broken fixture intact'
    $cache = Join-Path $workspace '.work/native-runtime'
    $preflight = Resolve-NativeKeycloakRuntime $workspace $root $manifest 'unused' -ValidateOnly
    Assert-Condition ($preflight.optimized -and !$preflight.runner -and ![IO.Directory]::Exists($cache)) 'Optimized preflight validates archive without staging files'
    $options = @(Get-NativeKeycloakJavaOptions (Join-Path $workspace 'home with spaces'))
    Assert-Condition ('--add-opens=java.base/java.lang=ALL-UNNAMED' -in $options -and
        "-Dkc.home.dir=$(Join-Path $workspace 'home with spaces')" -in $options) 'Java 25 can reset thread locals and home remains a single argument'

    Assert-Throws { Initialize-NativeKeycloakRuntime $workspace (Join-Path $workspace 'custom') $manifest } 'only for the default'
    [IO.File]::WriteAllText($version, 'Keycloak - Version 26.4.1')
    Assert-Throws { Invoke-Recovery } 'only for the default'
    [IO.File]::WriteAllText($version, $initialVersion)
    $self = Get-Process -Id $PID
    @{ pid = $PID; startTimeUtc = $self.StartTime.ToUniversalTime().ToString('o'); executable = $self.Path } |
        ConvertTo-Json | Set-Content -LiteralPath $manifest
    Assert-Throws { Invoke-Recovery } 'tracked Keycloak process is running'
    [IO.File]::Delete($manifest)
    $script:cimUnavailable = $true
    Assert-Throws { Invoke-Recovery } 'Cannot inspect Java'
    $script:cimUnavailable = $false
    foreach ($line in @($null, 'java.exe @unknown.args', 'java.exe -cp lib/quarkus-run.jar io.quarkus.bootstrap.runner.QuarkusEntryPoint', ('java.exe -Dkc.home.dir="' + "$root/bin/.." + '"'))) {
        $script:javaRows = @([pscustomobject]@{ CommandLine = $line })
        Assert-Throws { Invoke-Recovery } 'recovery was deferred'
    }
    Assert-Condition ((Get-ChildItem $build -Force).Count -eq 1) 'No bytes changed for live or uninspectable processes'
    $script:javaRows = @([pscustomobject]@{ CommandLine = 'java.exe -jar elasticmq.jar' }, [pscustomobject]@{ CommandLine = 'java.exe -Dkc.home.dir="D:/another/keycloak" QuarkusEntryPoint' })
    $sentinel = Join-Path $build 'user-file.txt'
    [IO.File]::WriteAllText($sentinel, 'preserve')
    $first = Invoke-Recovery
    Assert-Condition ($first -match 'Restored four' -and [IO.File]::ReadAllText($sentinel) -eq 'preserve') 'Restored only the four fixed entries'
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries | Where-Object { $_.Name -and $_.FullName -like 'keycloak-26.4.0/lib/quarkus/*' }) {
            $inputStream = $entry.Open()
            try { $fromZip = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inputStream)) } finally { $inputStream.Dispose() }
            Assert-Condition ((Get-FileHash -LiteralPath (Join-Path $build $entry.Name)).Hash -eq $fromZip) "Restored $($entry.Name) matches the archive"
        }
    } finally { $zip.Dispose() }
    # Partial interruption after the fourth rename but before marker deletion.
    [IO.File]::WriteAllText($marker, '')
    Assert-Condition ((Invoke-Recovery) -match 'Restored four' -and -not (Test-Path -LiteralPath $marker)) 'Interrupted replacement is retried as a complete set'
    if ($JavaHome) {
        $java = Join-Path $JavaHome 'bin/java.exe'
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, [IO.Path]::GetDirectoryName($root), $true)
        $realm = Join-Path $root 'data/import/vortexbird-realm.json'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($realm))
        [IO.File]::WriteAllText($realm, '{"realm":"fixture"}')
        $originalData = Get-FileHash -LiteralPath $realm
        $h2 = Join-Path $root 'data/h2/keycloakdb.mv.db'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($h2))
        [IO.File]::WriteAllText($h2, 'H2 fixture sentinel; never open as a database')
        $config = Join-Path $root 'conf/keycloak.conf'
        $configHash = (Get-FileHash -LiteralPath $config).Hash
        $created = Resolve-NativeKeycloakRuntime $workspace $root $manifest $java
        Assert-Condition ($created.optimized -and (Test-Path -LiteralPath $created.runner) -and
            $created.runner.StartsWith($cache + [IO.Path]::DirectorySeparatorChar)) 'Real offline build publishes prepared binaries outside the home'
        $stockHash = (Get-FileHash -LiteralPath (Join-Path $build 'generated-bytecode.jar')).Hash
        $preflight = Resolve-NativeKeycloakRuntime $workspace $root $manifest 'unused' -ValidateOnly
        Assert-Condition ($preflight.runner -eq $created.runner -and $stockHash -eq (Get-FileHash -LiteralPath (Join-Path $build 'generated-bytecode.jar')).Hash) 'Existing v1 cache preflight leaves the stock runtime untouched'
        $baseline = Invoke-OptimizedStartDryRun $created.runner
        Assert-Condition ($baseline.code -eq 2 -and $baseline.output -like '*first ever server start*') 'Cached runner with stock home reproduces the first-start rejection'
        $homeRunner = Install-NativeKeycloakCompiledArtifacts $workspace $root $manifest $created.runner
        Assert-Condition ($homeRunner -eq (Join-Path $root 'lib/quarkus-run.jar')) 'The active runner belongs to kc.home.dir'
        $after = Invoke-OptimizedStartDryRun $homeRunner
        Assert-Condition ($after.code -eq 0) "Real start --optimized --import-realm accepted the prepared home in dry run: $($after.output)"
        Assert-Condition ((Get-FileHash -LiteralPath $realm).Hash -eq $originalData.Hash -and (Get-FileHash -LiteralPath $config).Hash -eq $configHash -and
            [IO.File]::ReadAllText($h2) -ceq 'H2 fixture sentinel; never open as a database') 'H2 data, realm import and configuration were preserved'
        $before = (Get-Item -LiteralPath (Join-Path $build 'generated-bytecode.jar')).LastWriteTimeUtc
        $null = Install-NativeKeycloakCompiledArtifacts $workspace $root $manifest $created.runner
        Assert-Condition ($before -eq (Get-Item -LiteralPath (Join-Path $build 'generated-bytecode.jar')).LastWriteTimeUtc) 'Warm activation does not rewrite matching artifacts'
        $cached = Resolve-NativeKeycloakRuntime $workspace $root $manifest 'not-a-java-binary'
        Assert-Condition ($cached.runner -eq $created.runner) 'Warm restart reuses prepared libraries without running the compiler'
        $receipt = Join-Path $cache 'keycloak-26.4.0-h2-build-v1.txt'
        $saved = [IO.File]::ReadAllText($receipt)
        [IO.File]::WriteAllText($receipt, '../elsewhere')
        $preflight = Resolve-NativeKeycloakRuntime $workspace $root $manifest $java -ValidateOnly
        Assert-Condition ($preflight.optimized -and !$preflight.runner) 'An unrelated relative path is never selected'
        [IO.File]::WriteAllText($receipt, $saved)
        $dataFile = Join-Path (Split-Path $created.runner) 'quarkus/quarkus-application.dat'
        [IO.File]::Delete($dataFile)
        $preflight = Resolve-NativeKeycloakRuntime $workspace $root $manifest $java -ValidateOnly
        Assert-Condition (!$preflight.runner -and [IO.File]::ReadAllText($receipt) -eq $saved) 'Incomplete cache is not selected or mutated during preflight'
        $foldersBefore = @(Get-ChildItem -Directory -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'vortexbird-keycloak-build-*').FullName -join '|'
        Assert-Throws { Resolve-NativeKeycloakRuntime $workspace $root $manifest 'missing-java-executable-for-test' } 'missing-java-executable-for-test'
        Assert-Throws { Resolve-NativeKeycloakRuntime $workspace $root $manifest $java -BuildTimeoutSeconds 1 } 'exceeded 1 seconds'
        $foldersAfter = @(Get-ChildItem -Directory -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'vortexbird-keycloak-build-*').FullName -join '|'
        Assert-Condition ($foldersBefore -eq $foldersAfter -and [IO.File]::ReadAllText($receipt) -eq $saved) 'Failed or timed out compilation cleans owned staging and preserves old receipt'
    }
    [IO.File]::Delete($archive)
    Assert-Condition ($null -eq (Invoke-Recovery)) 'Healthy runtime needs neither recovery nor the archive'

    $mutex = Enter-NativeKeycloakLock $manifest
    try {
        $other = [PowerShell]::Create()
        try {
            $null = $other.AddScript({
                param($helper, $path)
                . $helper
                try { $lock = Enter-NativeKeycloakLock $path } catch { return $_.Exception.Message }
                try { 'unexpected acquired lock' } finally { $lock.ReleaseMutex(); $lock.Dispose() }
            }).AddArgument((Join-Path $infra 'scripts/Native-KeycloakRuntime.ps1')).AddArgument($manifest)
            $reply = $other.Invoke()
            Assert-Condition ($reply[0] -match 'Another VortexBird launcher') 'A second launcher cannot enter while validation or startup is in progress'
        } finally { $other.Dispose() }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $mutex = Enter-NativeKeycloakLock $manifest
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Assert-Condition $true 'A completed launcher releases its lock'
    [pscustomobject]@{ passed = $script:passed; failed = 0; servicesStarted = 0; scope = 'Isolated native Keycloak recovery and concurrency' } | ConvertTo-Json
} finally {
    if ([IO.Directory]::Exists($workspace)) {
        $target = [IO.Path]::GetFullPath($workspace)
        if ($target -ne [IO.Path]::Combine($temporaryRoot, $fixtureName) -or [IO.Path]::GetFileName($target) -notmatch '^vortexbird-keycloak-test-[a-f0-9]{32}$') { throw 'Unexpected fixture path.' }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
