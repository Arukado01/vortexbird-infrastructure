#requires -Version 7.4
[CmdletBinding()]
param([string]$TerraformPath, [switch]$PrepareOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Ecs-FirstReviewPlan.ps1')
. (Join-Path $PSScriptRoot 'Ecs-FirstReviewInventory.ps1')
$infra = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path $infra -Parent
$reviewRoot = Join-Path $workspace '.work/ecs-first-review'
$run = 'review-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N')
$runDir = Join-Path $reviewRoot $run
$configDir = Join-Path $runDir 'scratch'
$summaryFile = Join-Path $runDir 'NON-APPLICABLE-foundation-summary.json'
$region = 'us-east-2'
$expectedAccount = '946876341107'
$report = [ordered]@{
    startedUtc = [DateTime]::UtcNow.ToString('o'); region = $region; expectedAccountSuffix = '1107'
    mode = $(if ($PrepareOnly) { 'offline-preparation' } else { 'first-foundation-review' })
    profile = 'default'; environment = 'development'; identityFoundation = $true
    speculative = $true; applyExecuted = $false; remoteStateUsed = $false
    stages = [ordered]@{}; commands = [Collections.Generic.List[string]]::new()
    verifiedAccount = $false; changes = $null; status = 'blocked'
}
New-Item -ItemType Directory -Path $runDir | Out-Null

function Invoke-ReviewTool([string]$File, [string[]]$Arguments, [string]$Label, [int[]]$Allowed = @(0)) {
    $report.commands.Add($Label)
    $process = [Diagnostics.Process]::new()
    try {
        $start = $process.StartInfo
        $start.FileName = $File
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.WorkingDirectory = $runDir
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = $start.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($value in $Arguments) { $start.ArgumentList.Add($value) }
        # Use one default-profile credential chain for CLI and provider. Ignore inherited
        # TF arguments/workspaces/log files, explicit keys and alternate AWS endpoints.
        foreach ($key in @($start.Environment.Keys)) {
            if ($key -match '^(TF_|AWS_ENDPOINT_URL|AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|SECURITY_TOKEN|WEB_IDENTITY_TOKEN_FILE|ROLE_ARN|ROLE_SESSION_NAME)$)') {
                [void]$start.Environment.Remove($key)
            }
        }
        $start.Environment['AWS_PROFILE'] = 'default'
        $start.Environment['AWS_DEFAULT_PROFILE'] = 'default'
        $start.Environment['AWS_REGION'] = $start.Environment['AWS_DEFAULT_REGION'] = $region
        $start.Environment['AWS_IGNORE_CONFIGURED_ENDPOINT_URLS'] = 'true'
        $start.Environment['AWS_CLI_AUTO_PROMPT'] = 'off'
        $start.Environment['AWS_PAGER'] = ''
        $start.Environment['CHECKPOINT_DISABLE'] = '1'
        $start.Environment['TF_CLI_CONFIG_FILE'] = Join-Path $configDir 'empty.tfrc'
        $start.Environment['TF_IN_AUTOMATION'] = '1'
        $start.Environment['TF_DATA_DIR'] = Join-Path $configDir '.terraform'
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$Label (command timed out after five minutes)."
        }
        $result = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -notin $Allowed) {
            $kind = switch -Regex ($errorText + [Environment]::NewLine + $result) {
                'ExpiredToken|InvalidClientTokenId|Unable to locate credentials|credentials have expired|SSO session' { 'unavailable-or-expired-credentials'; break }
                'AccessDenied|UnauthorizedOperation|not authorized to perform' { 'access-denied'; break }
                'Could not load plugin|GetProviderSchema|Unrecognized remote plugin message|timeout while waiting for plugin' { 'provider-unavailable'; break }
                'Could not connect to the endpoint|dial tcp|failed to query available provider packages' { 'endpoint-unavailable'; break }
                default { 'command-failed' }
            }
            throw "$Label ($kind, exit $($process.ExitCode))."
        }
        return $result
    } finally { $process.Dispose() }
}

function Invoke-ReviewStage([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $report.stages[$Name] = @{ status = 'passed' }
    } catch {
        # Errors from native tools are already classified; never persist their raw output.
        $report.stages[$Name] = @{ status = 'blocked'; reason = $_.Exception.Message }
    }
}

try {
    $canonical = Join-Path $infra 'terraform-ecs'
    Invoke-ReviewStage 'prepare' {
        Copy-EcsFirstReviewSource $canonical $configDir
        [IO.File]::WriteAllText((Join-Path $configDir 'empty.tfrc'), '')
        $report.providerLockSha256 = (Get-FileHash -LiteralPath (Join-Path $configDir '.terraform.lock.hcl') -Algorithm SHA256).Hash
    }
    $toolsFound = @{}
    Invoke-ReviewStage 'terraform' {
        $candidate = $TerraformPath
        if (-not $candidate) { $candidate = (Get-Command terraform.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
        if (-not $candidate) { $candidate = Join-Path $workspace '.work/terraform-cli/terraform.exe' }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Supply an installed Terraform 1.x executable with -TerraformPath.' }
        $toolsFound.tf = (Resolve-Path -LiteralPath $candidate).Path
        $text = Invoke-ReviewTool $toolsFound.tf @('version','-json') 'terraform version -json'
        $version = ($text | ConvertFrom-Json -ErrorAction Stop).terraform_version
        if ($version -notmatch '^1\.(\d+)\.\d+$' -or [int]$Matches[1] -lt 10) { throw 'Terraform must meet the ECS constraint (1.10 or later, below 2.0).' }
        $report.terraformVersion = $version
    }
    if ($report.stages.prepare.status -eq 'passed' -and $report.stages.terraform.status -eq 'passed') {
        Invoke-ReviewStage 'format' {
            [void](Invoke-ReviewTool $toolsFound.tf @("-chdir=$configDir",'fmt','-check','-recursive') 'terraform fmt -check -recursive')
        }
    }
    if (-not $PrepareOnly) {
        Invoke-ReviewStage 'account' {
            $toolsFound.aws = (Get-Command aws.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            $argsList = @('sts','get-caller-identity','--query','Account','--region',$region,'--profile','default','--output','json','--no-cli-pager')
            $account = Invoke-ReviewTool $toolsFound.aws $argsList 'aws sts get-caller-identity'
            if ($account.Trim() -cne ('"' + $expectedAccount + '"')) { throw 'AWS default profile does not resolve to the expected Ohio account.' }
            $report.verifiedAccount = $true
        }
        if ($report.verifiedAccount) {
            Invoke-ReviewStage 'inventory' {
                Assert-EcsFirstReviewInventory {
                    param([string[]]$AwsArguments)
                    $label = 'aws ' + ($AwsArguments[0..1] -join ' ')
                    Invoke-ReviewTool $toolsFound.aws ($AwsArguments + @('--profile','default','--region',$region,'--output','json','--no-cli-pager')) $label
                }
            }
        }
        if ($report.stages.format.status -eq 'passed') {
            Invoke-ReviewStage 'initialize' {
                $initArgs = @("-chdir=$configDir",'init','-input=false','-lockfile=readonly','-no-color')
                $installed = Join-Path $canonical '.terraform/providers'
                $cache = Join-Path $workspace '.work/tf-cache'
                $awsProvider = 'registry.terraform.io/hashicorp/aws'
                $lockText = [IO.File]::ReadAllText((Join-Path $configDir '.terraform.lock.hcl'))
                if ($lockText -notmatch '(?s)provider "registry\.terraform\.io/hashicorp/aws"\s*\{\s*version\s*=\s*"([0-9.]+)"') { throw 'Missing AWS provider version in canonical lockfile.' }
                $lockedProvider = Join-Path $awsProvider ($Matches[1] + '/windows_amd64')
                foreach ($mirror in @($installed,$cache)) {
                    if (Test-Path -LiteralPath (Join-Path $mirror $lockedProvider) -PathType Container) {
                        $initArgs += "-plugin-dir=$mirror"
                        break
                    }
                }
                [void](Invoke-ReviewTool $toolsFound.tf $initArgs 'terraform init -input=false -lockfile=readonly (local backend)')
            }
            if ($report.stages.initialize.status -eq 'passed') {
                Invoke-ReviewStage 'validate' { [void](Invoke-ReviewTool $toolsFound.tf @("-chdir=$configDir",'validate','-no-color') 'terraform validate') }
            }
        }
        if ($report.stages.validate.status -eq 'passed' -and $report.stages.inventory.status -eq 'passed') {
            Invoke-ReviewStage 'speculativePlan' {
                $argsList = @("-chdir=$configDir",'plan','-json','-detailed-exitcode','-input=false','-lock=false','-var-file=environments/development.tfvars',
                    '-var=region=us-east-2','-var=deploy_services=false','-var=identity_enabled=true','-var=identity_deploy_service=false')
                # No -out: Terraform cannot apply this specific plan. Raw events live only in memory.
                $events = Invoke-ReviewTool $toolsFound.tf $argsList 'terraform plan -json -detailed-exitcode (development foundation, speculative)' @(0,2)
                $report.changes = Get-EcsFirstReviewChanges $events
            }
        }
    }
    $target = if ($PrepareOnly) { 'format' } else { 'speculativePlan' }
    if ($report.stages[$target].status -eq 'passed') { $report.status = if ($PrepareOnly) { 'prepared-offline' } else { 'planned-for-review' } }
} finally {
    if (Test-Path -LiteralPath $configDir) {
        $owned = [IO.Path]::GetFullPath((Join-Path $reviewRoot "$run/scratch"))
        if ((Resolve-Path -LiteralPath $configDir).Path -cne $owned) { throw 'Unexpected scratch location.' }
        try { Remove-Item -LiteralPath $configDir -Recurse -Force -ErrorAction Stop }
        catch {
            $report.stages.cleanup = @{ status = 'blocked'; reason = 'The temporary source/provider directory could not be removed.' }
            $report.status = 'blocked'
        }
    }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryFile -Encoding utf8NoBOM
    Write-Host "Foundation review $($report.status). Summary: $summaryFile"
}
[pscustomobject]@{
    status = $report.status; summaryPath = $summaryFile
    blockedStages = @($report.stages.Keys | Where-Object { $report.stages[$_].status -eq 'blocked' })
}
