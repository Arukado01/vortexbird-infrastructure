#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$infra = Split-Path $PSScriptRoot -Parent
. (Join-Path $infra 'scripts/Ecs-FirstReviewPlan.ps1')

function Assert-Blocked([scriptblock]$Action, [string]$Case) {
    try { [void](& $Action) } catch { return }
    throw "Expected review to block: $Case"
}

$addresses = @('aws_vpc.main','aws_db_instance.main','aws_db_instance.identity[0]','aws_lb.edge','aws_ecs_cluster.main')
function New-TestPlan([string[]]$Items = $addresses, [string]$Action = 'create', [int]$ChangeCount = 0) {
    $lines = @(foreach ($address in $Items) {
        @{
            type = 'planned_change'; change = @{ action = $Action; resource = @{ addr = $address; resource_type = $address.Split('.')[0] } }
            '@message' = 'sensitive-value-that-must-never-be-retained'
        } | ConvertTo-Json -Compress -Depth 5
    })
    $lines += @{ type = 'change_summary'; changes = @{ operation = 'plan'; add = $Items.Count; change = $ChangeCount; remove = 0 } } | ConvertTo-Json -Compress
    return ($lines -join [Environment]::NewLine)
}

$plan = New-TestPlan
$changes = Get-EcsFirstReviewChanges $plan
if ($changes.create -ne 5 -or $changes.resourcesByType.Count -ne 4 -or -not $changes.identityDatabase) { throw 'Wrong foundation totals.' }
if (($changes | ConvertTo-Json -Depth 5) -like '*sensitive-value*') { throw 'Raw Terraform content leaked into the summary.' }
Assert-Blocked { Get-EcsFirstReviewChanges (New-TestPlan -Action 'delete') } 'non-create action'
Assert-Blocked { Get-EcsFirstReviewChanges (New-TestPlan -ChangeCount 1) } 'inconsistent totals'
Assert-Blocked { Get-EcsFirstReviewChanges (New-TestPlan -Items $addresses[0..3]) } 'missing ECS cluster'
Assert-Blocked { Get-EcsFirstReviewChanges (New-TestPlan -Items ($addresses + $addresses[0])) } 'duplicate address'
foreach ($extra in @('aws_ecs_service.api','aws_ecs_task_definition.identity','aws_lb_listener.http','aws_route53_record.identity','aws_acm_certificate.identity','aws_elasticache_replication_group.main')) {
    Assert-Blocked { Get-EcsFirstReviewChanges (New-TestPlan -Items ($addresses + $extra)) } $extra
}
Assert-Blocked { Get-EcsFirstReviewChanges 'not JSON' } 'malformed output'
Assert-Blocked { Get-EcsFirstReviewChanges ($plan + [Environment]::NewLine + '{"type":"diagnostic","diagnostic":{"severity":"error"}}') } 'error diagnostics'

$review = & (Join-Path $infra 'scripts/New-EcsFirstReview.ps1') -PrepareOnly
if ($review.status -ne 'prepared-offline') { throw 'Offline source and format check failed.' }
$proof = Get-Content -LiteralPath $review.summaryPath -Raw | ConvertFrom-Json
if ($proof.verifiedAccount -or $proof.changes -or $proof.applyExecuted -or $proof.commands -match 'aws|terraform (init|plan)') { throw 'Offline execution attempted a connected stage.' }
$remaining = @(Get-ChildItem -LiteralPath (Split-Path $review.summaryPath -Parent) -Force)
if ($remaining.Count -ne 1 -or $remaining[0].FullName -ne $review.summaryPath) { throw 'Only the redacted summary may remain.' }
Write-Output 'PASS: speculative plan summary, sensitive-output filtering, foundation guards, offline preparation and cleanup.'
