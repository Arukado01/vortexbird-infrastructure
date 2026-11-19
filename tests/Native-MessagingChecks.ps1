#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Start-Native-Messaging.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Messaging script contains PowerShell syntax errors.' }
# Load only the pure response parser, never the launcher or its prerequisites.
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ElasticMqQueueResponse' }, $true)
if (-not $function) { throw 'Missing isolated queue response parser.' }
. ([scriptblock]::Create($function.Extent.Text))
$endpoint = 'http://127.0.0.1:9324'
$main = "$endpoint/000000000000/vortexbird-events"
$dlq = "$endpoint/000000000000/vortexbird-events-dlq"
function New-ListQueuesFixture([string[]]$Urls, [switch]$NoNamespace) {
    $namespace = if ($NoNamespace) { '' } else { ' xmlns="http://queue.amazonaws.com/doc/2012-11-05/"' }
    $entries = ($Urls | ForEach-Object { '<QueueUrl>' + [System.Security.SecurityElement]::Escape($_) + '</QueueUrl>' }) -join ''
    return "<ListQueuesResponse$namespace><ListQueuesResult>$entries</ListQueuesResult><ResponseMetadata><RequestId>fixture</RequestId></ResponseMetadata></ListQueuesResponse>"
}
$cases = @(
    @{ Name='only DLQ is rejected'; Xml=(New-ListQueuesFixture @($dlq)); Expected=$false },
    @{ Name='only primary is rejected'; Xml=(New-ListQueuesFixture @($main)); Expected=$false },
    @{ Name='both exact queue URLs are accepted'; Xml=(New-ListQueuesFixture @($main,$dlq)); Expected=$true },
    @{ Name='queue order and unrelated queues do not matter'; Xml=(New-ListQueuesFixture @($dlq,"$endpoint/000000000000/another-queue",$main)); Expected=$true },
    @{ Name='unqualified Query XML is accepted'; Xml=(New-ListQueuesFixture @($main,$dlq) -NoNamespace); Expected=$true },
    @{ Name='same names on a foreign endpoint are rejected'; Xml=(New-ListQueuesFixture @($main.Replace('127.0.0.1','localhost'),$dlq.Replace('127.0.0.1','localhost'))); Expected=$false },
    @{ Name='same names in a different account are rejected'; Xml=(New-ListQueuesFixture @($main.Replace('000000000000','111111111111'),$dlq.Replace('000000000000','111111111111'))); Expected=$false },
    @{ Name='queue suffixes do not match exact URLs'; Xml=(New-ListQueuesFixture @("$main-extra",$dlq)); Expected=$false },
    @{ Name='empty queue list is rejected'; Xml=(New-ListQueuesFixture @()); Expected=$false },
    @{ Name='malformed XML is rejected'; Xml='<ListQueuesResponse'; Expected=$false },
    @{ Name='names in an error response are rejected'; Xml="<ErrorResponse><Message>$main $dlq</Message></ErrorResponse>"; Expected=$false },
    @{ Name='DTD is rejected before entity resolution'; Xml='<!DOCTYPE ListQueuesResponse [<!ENTITY x SYSTEM "file:///never-read">]><ListQueuesResponse><ListQueuesResult><QueueUrl>&x;</QueueUrl></ListQueuesResult></ListQueuesResponse>'; Expected=$false }
)
foreach ($case in $cases) {
    $actual = Test-ElasticMqQueueResponse -Content $case.Xml -Endpoint $endpoint
    if ($actual -ne $case.Expected) { throw "FAIL: $($case.Name)" }
    Write-Output "PASS: $($case.Name)"
}
Write-Output "Native messaging response checks: $($cases.Count) passed. No services, sockets or AWS calls."
