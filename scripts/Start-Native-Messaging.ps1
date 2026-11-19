#requires -Version 7.4
[CmdletBinding()]
param([string]$ElasticMqJar, [string]$JavaHome, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native-ProcessIdentity.ps1')
$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
if (-not $ElasticMqJar) { $ElasticMqJar = Join-Path $workspaceRoot '.work/elasticmq-1.6.12.jar' }
$jar = (Resolve-Path -LiteralPath $ElasticMqJar).Path
if ($JavaHome) {
    $java = Join-Path ([IO.Path]::GetFullPath($JavaHome)) 'bin/java.exe'
    if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { throw "Missing Java executable: $java. No messaging process was started." }
} else {
    $javaCommand = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $javaCommand) { throw 'Java is not on PATH. Supply -JavaHome with a JDK installation; no messaging process was started.' }
    $java = $javaCommand.Source
}
$runtimeDirectory = Join-Path $workspaceRoot '.work/native-messaging'
$stateFile = Join-Path $runtimeDirectory 'process.json'
$configuration = Join-Path $infraRoot 'messaging/elasticmq-native.conf'
if (-not (Test-Path -LiteralPath $configuration -PathType Leaf)) { throw "Missing ElasticMQ configuration: $configuration. No messaging process was started." }
$endpoint = 'http://127.0.0.1:9324'
if ($ValidateOnly) {
    Write-Output 'ElasticMQ native prerequisites valid. No files, connections or processes were changed.'
    return
}

function Test-ElasticMqQueueResponse([string]$Content, [string]$Endpoint) {
    # Query API responses use ListQueuesResult/QueueUrl, normally with the SQS
    # default XML namespace. Match complete URLs; the DLQ name includes the
    # primary name and therefore cannot be checked with substring matching.
    $reader = $null
    $textReader = $null
    try {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $textReader = [System.IO.StringReader]::new($Content)
        $reader = [System.Xml.XmlReader]::Create($textReader, $settings)
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        $urls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($element in $document.SelectNodes('/*[local-name()="ListQueuesResponse"]/*[local-name()="ListQueuesResult"]/*[local-name()="QueueUrl"]')) {
            [void]$urls.Add($element.InnerText.Trim())
        }
        $queuePrefix = $Endpoint.TrimEnd('/') + '/000000000000/'
        return $urls.Contains($queuePrefix + 'vortexbird-events') -and $urls.Contains($queuePrefix + 'vortexbird-events-dlq')
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($textReader) { $textReader.Dispose() }
    }
}

function Test-QueueEndpoint {
    try {
        $response = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/x-www-form-urlencoded' -Body 'Action=ListQueues&Version=2012-11-05' -TimeoutSec 3
        return $response.StatusCode -eq 200 -and (Test-ElasticMqQueueResponse -Content $response.Content -Endpoint $endpoint)
    } catch { return $false }
}

if (Test-Path -LiteralPath $stateFile) {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $existing = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
    $ownedProcess = Test-NativeProcessIdentity $existing $state.processId $state.startedAt $state.executable
    if ($ownedProcess -and (Test-QueueEndpoint)) {
        Write-Output 'ElasticMQ native: PASS (existing owned process; events and DLQ respond on 127.0.0.1:9324)'
        return
    }
    if ($ownedProcess) { throw 'The existing messaging process is unhealthy; inspect .work/native-messaging logs and run Stop-Native-Messaging.ps1 before restarting.' }
}
try { $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) }
catch { throw "Cannot inspect local TCP listeners: $($_.Exception.Message). Port 9324 is unknown, not free. No messaging process was started." }
if ($listeners | Where-Object LocalPort -eq 9324) { throw 'Port 9324 is occupied by another process. No process was stopped or replaced.' }
New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
$arguments = @('-Dconfig.file="' + $configuration + '"', '-jar', '"' + $jar + '"')
$process = Start-Process -FilePath $java -ArgumentList $arguments -WindowStyle Hidden -PassThru -WorkingDirectory $runtimeDirectory -RedirectStandardOutput (Join-Path $runtimeDirectory 'stdout.log') -RedirectStandardError (Join-Path $runtimeDirectory 'stderr.log')
$state = @{ processId = $process.Id; startedAt = $process.StartTime.ToUniversalTime().ToString('o'); executable = $java; endpoint = $endpoint; jarSha256 = (Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash }
$state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
$deadline = [DateTime]::UtcNow.AddSeconds(45)
do {
    $process.Refresh()
    if ($process.HasExited) { throw 'ElasticMQ exited before readiness. Inspect .work/native-messaging/stderr.log and stdout.log.' }
    if (Test-QueueEndpoint) {
        Write-Output 'ElasticMQ native: PASS (events and DLQ respond on 127.0.0.1:9324)'
        return
    }
    Start-Sleep -Seconds 1
} while ([DateTime]::UtcNow -lt $deadline)
throw 'ElasticMQ readiness timed out. No AWS services were contacted; inspect the local messaging logs.'
