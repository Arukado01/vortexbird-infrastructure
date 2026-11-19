# All managed launchers in this workspace share a process manifest. Hold the
# mutex through readiness so no other launcher repairs during augmentation.
function Enter-NativeKeycloakLock([string]$manifestPath) {
    $key = [IO.Path]::GetFullPath($manifestPath).ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
    $mutex = [Threading.Mutex]::new($false, "Local\VortexBird-Keycloak-$hash")
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another VortexBird launcher is checking or starting Keycloak. Wait for that run to finish.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Assert-NativeKeycloakIdle([string]$root, [string]$manifestPath) {
    if ([IO.File]::Exists($manifestPath)) {
        $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
        if (Test-NativeProcessIdentity $process $record.pid $record.startTimeUtc $record.executable) {
            throw 'The tracked Keycloak process is running. Recovery was deferred.'
        }
    }
    # A manual kc.bat launch need not have a VortexBird manifest. The command
    # line is inspected locally and never included in logs or error messages.
    try { $javaProcesses = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop) }
    catch { throw 'Cannot inspect Java processes before Keycloak recovery. Run the launcher in your normal Windows session.' }
    foreach ($javaProcess in $javaProcesses) {
        $line = $javaProcess.CommandLine
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '(?:^|\s)"?@') {
            throw 'A Java process has uninspectable arguments. Keycloak recovery was deferred.'
        }
        if ($line -notmatch 'keycloak|quarkus-run\.jar|QuarkusEntryPoint|kc\.home\.dir') { continue }
        # Both kc.bat's forward slashes and its bin/.. designation normalize
        # to the installation root. Unknown locations must not be guessed.
        if ($line -match '(?:^|\s)(?:"-Dkc\.home\.dir=([^"]+)"|-Dkc\.home\.dir="([^"]+)"|-Dkc\.home\.dir=([^"\s]+))') {
            $homeValue = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ } | Select-Object -First 1
            if ([IO.Path]::IsPathFullyQualified($homeValue) -and
                [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($homeValue)) -ne $root) { continue }
        }
        throw 'A Java process may be using this Keycloak installation. Recovery was deferred.'
    }
}

function Assert-NativeKeycloakArtifactPaths([string]$workspaceRoot, [string]$build, [string[]]$names) {
    # Do not follow directory links, even if their text is inside the workspace.
    $parent = $build
    while ($parent -ne $workspaceRoot) {
        if (-not $parent) { throw 'The Keycloak recovery directory is outside the workspace.' }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Keycloak recovery refuses linked directories.' }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    foreach ($name in @($names) + '.vortexbird-repair-pending') {
        $item = Get-Item -LiteralPath (Join-Path $build $name) -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Keycloak recovery refuses linked artifacts.' }
    }
}

function Initialize-NativeKeycloakRuntime([string]$workspaceRoot, [string]$root, [string]$manifestPath, [switch]$ValidateOnly) {
    $names = @('quarkus-application.dat', 'build-system.properties', 'generated-bytecode.jar', 'transformed-bytecode.jar')
    $build = Join-Path $root 'lib/quarkus'
    $marker = Join-Path $build '.vortexbird-repair-pending'
    $incomplete = [IO.File]::Exists($marker)
    foreach ($name in $names) {
        $path = Join-Path $build $name
        try {
            if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -eq 0) { $incomplete = $true; break }
            if ($name.EndsWith('.jar')) {
                $jar = [IO.Compression.ZipFile]::OpenRead($path)
                try { if ($jar.Entries.Count -eq 0) { $incomplete = $true; break } } finally { $jar.Dispose() }
            }
        } catch { $incomplete = $true; break }
    }
    if (-not $incomplete) { return }
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot '.work/validation-20261117/keycloak-26.4.0'))
    if ($root -ne $defaultRoot -or [IO.File]::ReadAllText((Join-Path $root 'version.txt')).Trim() -ne 'Keycloak - Version 26.4.0') {
        throw 'Incomplete Keycloak runtime. Automatic recovery is available only for the default Keycloak 26.4.0 distribution.'
    }
    Assert-NativeKeycloakArtifactPaths $workspaceRoot $build $names
    $archivePath = Join-Path $workspaceRoot '.work/closure-keycloak.zip'
    $archiveFile = [IO.File]::Open($archivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveFile))
        if ($digest -ne '1B6A11A2726AC8A8DC9C91D5FAFE989A75CE4F1622D7F7B45C21D5BC16629C0A') {
            throw 'Keycloak recovery archive has an unexpected SHA-256. The installation was preserved.'
        }
        if ($ValidateOnly) {
            Write-Output 'Incomplete Keycloak bytecode is recoverable from the verified local 26.4.0 archive when the installation is idle.'
            return
        }
        Assert-NativeKeycloakIdle $root $manifestPath
        $archiveFile.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($archiveFile, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            [void][IO.Directory]::CreateDirectory($build)
            # The marker makes a crash between atomic file replacements retryable.
            # CreateNew avoids writing through an existing link or hard link.
            if (-not [IO.File]::Exists($marker)) { [IO.File]::Open($marker, [IO.FileMode]::CreateNew).Dispose() }
            $temporary = Join-Path $build ('.vortexbird-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                foreach ($name in $names) {
                    $entry = $archive.GetEntry("keycloak-26.4.0/lib/quarkus/$name")
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $temporary)
                    [IO.File]::Move($temporary, (Join-Path $build $name), $true)
                }
                [IO.File]::Delete($marker)
            } finally { [IO.File]::Delete($temporary) }
        } finally { $archive.Dispose() }
    } finally { $archiveFile.Dispose() }
    Write-Output 'Restored four Keycloak bytecode files from the verified local 26.4.0 archive.'
}

# Keycloak reads its persisted build options relative to kc.home.dir, even when
# the Quarkus runner is on another classpath. Activate the compiled files in
# the managed home, retaining its existing data, import, configuration and themes.
function Install-NativeKeycloakCompiledArtifacts([string]$workspaceRoot, [string]$root, [string]$manifestPath, [string]$compiledRunner) {
    $names = @('quarkus-application.dat','build-system.properties','generated-bytecode.jar','transformed-bytecode.jar')
    $source = Join-Path ([IO.Path]::GetDirectoryName($compiledRunner)) 'quarkus'
    $destination = Join-Path $root 'lib/quarkus'
    Assert-NativeKeycloakArtifactPaths $workspaceRoot $destination $names
    $marker = Join-Path $destination '.vortexbird-repair-pending'
    $needsInstall = [IO.File]::Exists($marker)
    foreach ($name in $names) {
        $target = Join-Path $destination $name
        if ($needsInstall -or ![IO.File]::Exists($target) -or
            (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source $name)).Hash) {
            $needsInstall = $true
            break
        }
    }
    if ($needsInstall) {
        Assert-NativeKeycloakIdle $root $manifestPath
        [void][IO.Directory]::CreateDirectory($destination)
        if (![IO.File]::Exists($marker)) { [IO.File]::Open($marker, [IO.FileMode]::CreateNew).Dispose() }
        $temporary = Join-Path $destination ('.vortexbird-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            foreach ($name in $names) {
                [IO.File]::Copy((Join-Path $source $name), $temporary)
                [IO.File]::Move($temporary, (Join-Path $destination $name), $true)
            }
            [IO.File]::Delete($marker)
        } finally { [IO.File]::Delete($temporary) }
    }
    return (Join-Path $root 'lib/quarkus-run.jar')
}

function Get-NativeKeycloakJavaOptions([string]$homeDirectory) {
    '-Xms64m', '-Xmx512m', '-Duser.language=en', '-Duser.country=US',
        '--add-opens=java.base/java.lang=ALL-UNNAMED',
        '--add-opens=java.base/java.util=ALL-UNNAMED',
        '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
        '--add-opens=java.base/java.security=ALL-UNNAMED',
        '-Djava.util.concurrent.ForkJoinPool.common.threadFactory=io.quarkus.bootstrap.forkjoin.QuarkusForkJoinWorkerThreadFactory',
        '-Djava.util.logging.manager=org.jboss.logmanager.LogManager',
        '-Dquarkus-log-max-startup-records=10000', '-Dpicocli.disable.closures=true',
        "-Dkc.home.dir=$homeDirectory", "-Djboss.server.config.dir=$(Join-Path $homeDirectory 'conf')",
        "-Dkeycloak.theme.dir=$(Join-Path $homeDirectory 'themes')"
}

function Test-NativeKeycloakOptimizedLibrary([string]$lib) {
    foreach ($name in @('quarkus-run.jar','app/keycloak.jar','quarkus/quarkus-application.dat','quarkus/build-system.properties','quarkus/transformed-bytecode.jar')) {
        $file = Get-Item -LiteralPath (Join-Path $lib $name) -ErrorAction SilentlyContinue
        if (!$file -or !$file.Length) { return $false }
    }
    try {
        $jar = [IO.Compression.ZipFile]::OpenRead((Join-Path $lib 'quarkus/generated-bytecode.jar'))
        try {
            $entry = $jar.GetEntry('META-INF/keycloak-persisted.properties')
            if (!$entry) { return $false }
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $settings = $reader.ReadToEnd().Split([char]10).Trim() } finally { $reader.Dispose() }
            foreach ($expected in @('kc.db=dev-file','kc.health-enabled=true','kc.metrics-enabled=true','kc.profile=prod')) {
                if ($expected -cnotin $settings) { return $false }
            }
        } finally { $jar.Dispose() }
    } catch { return $false }
    return $true
}

# Generated JARs can be read from the workspace even on Windows volumes
# where Java's ZIP filesystem cannot rewrite them. Persist only the compiled
# libraries. Realm data, settings and identities stay under the original home.
function Resolve-NativeKeycloakRuntime([string]$workspaceRoot, [string]$root, [string]$manifestPath, [string]$java, [switch]$ValidateOnly, [ValidateRange(1,900)][int]$BuildTimeoutSeconds = 240) {
    $source = Join-Path $workspaceRoot '.work/closure-keycloak.zip'
    $defaultRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot '.work/validation-20261117/keycloak-26.4.0'))
    $legacy = @{ runner = (Join-Path $root 'lib/quarkus-run.jar'); optimized = $false }
    $cacheRoot = Join-Path $workspaceRoot '.work/native-runtime'
    $receipt = Join-Path $cacheRoot 'keycloak-26.4.0-h2-build-v1.txt'
    if ($root -ne $defaultRoot -or !(Test-Path -LiteralPath (Join-Path $root 'version.txt') -PathType Leaf) -or
        [IO.File]::ReadAllText((Join-Path $root 'version.txt')).Trim() -ne 'Keycloak - Version 26.4.0' -or
        @(Get-ChildItem -LiteralPath (Join-Path $root 'providers') -File -Filter '*.jar' -ErrorAction SilentlyContinue).Count) {
        Initialize-NativeKeycloakRuntime $workspaceRoot $root $manifestPath -ValidateOnly:$ValidateOnly | Out-Host
        return $legacy
    }
    foreach ($dir in @((Join-Path $workspaceRoot '.work'), $cacheRoot)) {
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Keycloak build refuses a linked cache directory.' }
    }
    if ([IO.File]::Exists($receipt)) {
        $folder = [IO.File]::ReadAllText($receipt).Trim()
        if ($folder -match '^keycloak-build-[a-f0-9]{32}$') {
            $lib = Join-Path $cacheRoot "$folder/lib"
            if (Test-NativeKeycloakOptimizedLibrary $lib) {
                return @{ runner = (Join-Path $lib 'quarkus-run.jar'); optimized = $true }
            }
        }
    }
    if (![IO.File]::Exists($source)) {
        Initialize-NativeKeycloakRuntime $workspaceRoot $root $manifestPath -ValidateOnly:$ValidateOnly | Out-Host
        return $legacy
    }
    $id = [guid]::NewGuid().ToString('N')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stage = Join-Path $tempRoot "vortexbird-keycloak-build-$id"
    $buildHome = Join-Path $stage 'keycloak-26.4.0'
    $folder = "keycloak-build-$id"
    $published = Join-Path $cacheRoot $folder
    $receiptTemp = Join-Path $cacheRoot "$folder.tmp"
    $ownsStage = $false
    $ownsPartial = $false
    try {
        $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) -ne '1B6A11A2726AC8A8DC9C91D5FAFE989A75CE4F1622D7F7B45C21D5BC16629C0A') {
                throw 'Keycloak recovery archive has an unexpected SHA-256. The installation was preserved.'
            }
            if ($ValidateOnly) { return @{runner = $null; optimized = $true} }
            [void](New-Item -ItemType Directory -Path $stage -ErrorAction Stop)
            $ownsStage = $true
            $stream.Position = 0
            [IO.Compression.ZipFile]::ExtractToDirectory($stream, $stage)
        } finally { $stream.Dispose() }
        $psi = [Diagnostics.ProcessStartInfo]::new($java)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $buildHome
        # Build once with fixed settings, independent of the caller's Keycloak
        # environment. No user data or bootstrap credentials enter the staging tree.
        foreach ($key in @($psi.Environment.Keys)) {
            if ($key -match '^(KC_|KCRAW_|QUARKUS_|JAVA_TOOL_OPTIONS$|JDK_JAVA_OPTIONS$|_JAVA_OPTIONS$)') { [void]$psi.Environment.Remove($key) }
        }
        $arguments = @(Get-NativeKeycloakJavaOptions $buildHome) + @('-cp', (Join-Path $buildHome 'lib/quarkus-run.jar'),
            'io.quarkus.bootstrap.runner.QuarkusEntryPoint', 'build', '--db=dev-file', '--health-enabled=true', '--metrics-enabled=true')
        foreach ($argument in $arguments) { $psi.ArgumentList.Add($argument) }
        $compiler = [Diagnostics.Process]::Start($psi)
        try {
            if (!$compiler.WaitForExit($BuildTimeoutSeconds * 1000)) {
                if (!$compiler.HasExited) { $compiler.Kill() }
                [void]$compiler.WaitForExit(5000)
                throw "Keycloak offline build exceeded $BuildTimeoutSeconds seconds."
            }
            if ($compiler.ExitCode -ne 0) { throw "Keycloak offline build failed with exit code $($compiler.ExitCode)." }
        } finally { $compiler.Dispose() }
        [void][IO.Directory]::CreateDirectory($cacheRoot)
        [void](New-Item -ItemType Directory -Path $published -ErrorAction Stop)
        $ownsPartial = $true
        Copy-Item -LiteralPath (Join-Path $buildHome 'lib') -Destination $published -Recurse -ErrorAction Stop
        if (!(Test-NativeKeycloakOptimizedLibrary (Join-Path $published 'lib'))) { throw 'Compiled Keycloak runtime is incomplete or has unexpected settings.' }
        [IO.File]::WriteAllText($receiptTemp, $folder)
        [IO.File]::Move($receiptTemp, $receipt, $true)
        $ownsPartial = $false
        return @{ runner = (Join-Path $published 'lib/quarkus-run.jar'); optimized = $true }
    } finally {
        $target = [IO.Path]::GetFullPath($stage)
        if ($ownsStage -and $target -eq [IO.Path]::Combine($tempRoot, "vortexbird-keycloak-build-$id")) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        $partial = [IO.Path]::GetFullPath($published)
        if ($ownsPartial -and $partial -eq [IO.Path]::Combine($cacheRoot,"keycloak-build-$id")) {
            [IO.File]::Delete($receiptTemp)
            Remove-Item -LiteralPath $partial -Recurse -Force
        }
    }
}
