#requires -Version 7.4
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/Ecs-FirstReviewInventory.ps1')

$emptyPage = '{"kind":"array","items":[],"empty":false,"pagination":[null,null,null,null,null,null,null,null]}'
$fixture = [ordered]@{}
$reads = [Collections.Generic.List[string]]::new()
$read = {
    param([string[]]$Arguments)
    $key = $Arguments[0..1] -join ' '
    $reads.Add($key)
    if ($Arguments -notcontains '--query' -or $Arguments -contains '--no-paginate' -or $Arguments -contains '--max-items') {
        throw 'Inventory must support automatic pagination'
    }
    if ($fixture.Contains($key)) { return $fixture[$key] }
    return $emptyPage
}
function Test-InventoryResult([string]$Command, [string]$Json, [string]$Expected) {
    $fixture.Clear()
    $fixture[$Command] = $Json
    $errorMessage = $null
    try { Assert-EcsFirstReviewInventory $read } catch { $errorMessage = $_.Exception.Message }
    if ($Expected) {
        if (!$errorMessage -or $errorMessage -notlike "*$Expected*" -or $errorMessage -match 'private-value') {
            throw "Expected sanitized inventory rejection for '$Command'."
        }
    } elseif ($errorMessage) { throw $errorMessage }
    $script:passed++
}
function New-TestPage($Items) {
    $page = ConvertFrom-Json $emptyPage -AsHashtable
    $page.items = @($Items)
    $page | ConvertTo-Json -Depth 8 -Compress
}
$passed = 0
$unrelated = New-TestPage @('pge-development','AUXO')
Test-InventoryResult 'ecs list-clusters' $unrelated ''
if ($reads.Count -ne 19 -or $null -eq ($reads | Where-Object {$_ -eq 'eks list-clusters'})) { throw 'Incomplete inventory coverage.' }
Test-InventoryResult 'sqs list-queues' ($emptyPage.Replace('"array"','"null"').Replace('false','true')) ''
Test-InventoryResult 'sqs list-queues' ($emptyPage.Replace('"array"','"null"')) 'unexpected inventory'
Test-InventoryResult 'ecr describe-repositories' ($emptyPage.Replace('"array"','"null"').Replace('false','true')) 'unexpected inventory'
Test-InventoryResult 'iam list-roles' ($emptyPage.Replace('[null,null','["private-value",null')) 'incomplete'
Test-InventoryResult 'eks list-clusters' '{}' 'unexpected inventory'
Test-InventoryResult 'ecs list-clusters' '{"private-value"' 'unexpected inventory'
Test-InventoryResult 'rds describe-db-instances' ($emptyPage.Replace('[]','[null]')) 'unrecognized resource'
Test-InventoryResult 's3api list-buckets' (New-TestPage @('team-vortexbird-archive-private-value')) 'naming collision'
$archive = 'vortexbird-entregas-ohio-7af23d90'
$archiveArn = "arn:aws:s3:::$archive"
Test-InventoryResult 's3api list-buckets' (New-TestPage @($archive)) ''
Test-InventoryResult 'resourcegroupstaggingapi get-resources' (New-TestPage @($archiveArn)) ''
Test-InventoryResult 's3api list-buckets' (New-TestPage @($archive, "$archive-backup")) 'naming collision'
Test-InventoryResult 'resourcegroupstaggingapi get-resources' (New-TestPage @($archiveArn, "$archiveArn/object")) 'project resource'
Test-InventoryResult 'ecs list-clusters' (New-TestPage @($archive)) 'naming collision'
Test-InventoryResult 'resourcegroupstaggingapi get-resources' (New-TestPage @('private-value')) 'project resource'
Test-InventoryResult 'elbv2 describe-target-groups' (New-TestPage @('vb-id-development')) 'naming collision'
Test-InventoryResult 'elbv2 describe-target-groups' (New-TestPage @('vb-ecs-development-api')) 'naming collision'

$vpc = @{primary='10.42.0.0/16'; associations=@(@{cidr='10.42.0.0/16';state='associated'}, @{cidr='10.74.2.0/24';state='disassociated'})}
Test-InventoryResult 'ec2 describe-vpcs' (New-TestPage @($vpc)) ''
$vpc.associations[1].state = 'associating'
Test-InventoryResult 'ec2 describe-vpcs' (New-TestPage @($vpc)) 'overlaps'
$vpc.associations[1].cidr = '10.0.0.0/8'
Test-InventoryResult 'ec2 describe-vpcs' (New-TestPage @($vpc)) 'overlaps'
$vpc.associations[1].cidr = 'private-value'
Test-InventoryResult 'ec2 describe-vpcs' (New-TestPage @($vpc)) 'could not be verified'
$vpc.associations = @()
Test-InventoryResult 'ec2 describe-vpcs' (New-TestPage @($vpc)) 'could not be verified'
$message = $null
try { Assert-EcsFirstReviewInventory { throw 'private-value' } } catch { $message = $_.Exception.Message }
if ($message -notlike '*unreadable*' -or $message -match 'private-value') { throw 'Reader failure not sanitized.' }
$passed++
[pscustomobject]@{passed=$passed; awsRequests=0; scope='ECS first review inventory fixtures'} | ConvertTo-Json
