#requires -Version 7.4

# The callback runs one read-only AWS CLI command with automatic pagination
# and returns its JSON stdout. Its caller pins the AWS account and region.
function Assert-EcsFirstReviewInventory {
    param([Parameter(Mandatory)][scriptblock]$ReadAws)

    $checks = @(
        @{ Command = 'resourcegroupstaggingapi get-resources'; List = 'ResourceTagMappingList'; Item = 'ResourceARN'; Options = @('--tag-filters','Key=Project,Values=VortexBird') }
        @{ Command = 'ecs list-clusters'; List = 'clusterArns' }
        @{ Command = 'ecs list-task-definition-families'; List = 'families'; Options = @('--status','ACTIVE') }
        @{ Command = 'eks list-clusters'; List = 'clusters' }
        @{ Command = 'ecr describe-repositories'; List = 'repositories'; Item = 'repositoryName' }
        @{ Command = 'rds describe-db-instances'; List = 'DBInstances'; Item = 'DBInstanceIdentifier' }
        @{ Command = 'rds describe-db-subnet-groups'; List = 'DBSubnetGroups'; Item = 'DBSubnetGroupName' }
        @{ Command = 'elbv2 describe-load-balancers'; List = 'LoadBalancers'; Item = 'LoadBalancerName' }
        @{ Command = 'elbv2 describe-target-groups'; List = 'TargetGroups'; Item = 'TargetGroupName' }
        @{ Command = 'ec2 describe-security-groups'; List = 'SecurityGroups'; Item = 'GroupName' }
        @{ Command = 'elasticache describe-replication-groups'; List = 'ReplicationGroups'; Item = 'ReplicationGroupId' }
        @{ Command = 'elasticache describe-cache-subnet-groups'; List = 'CacheSubnetGroups'; Item = 'CacheSubnetGroupName' }
        @{ Command = 'sqs list-queues'; List = 'QueueUrls'; Options = @('--page-size','1000') }
        @{ Command = 'secretsmanager list-secrets'; List = 'SecretList'; Item = 'Name'; Options = @('--include-planned-deletion') }
        @{ Command = 'logs describe-log-groups'; List = 'logGroups'; Item = 'logGroupName' }
        @{ Command = 'iam list-roles'; List = 'Roles'; Item = 'RoleName' }
        @{ Command = 'cloudformation list-stacks'; List = 'StackSummaries'; Item = 'StackName' }
        @{ Command = 's3api list-buckets'; List = 'Buckets'; Item = 'Name' }
        @{ Command = 'ec2 describe-vpcs'; List = 'Vpcs'; Item = '{primary:CidrBlock,associations:map(&{cidr:CidrBlock,state:CidrBlockState.State},CidrBlockAssociationSet)}' }
    )
    # This source archive is managed separately from the ECS foundation and its backend.
    $sourceArchiveBucket = 'vortexbird-entregas-ohio-7af23d90'
    $development = [System.Net.IPNetwork]::Parse('10.74.0.0/16')
    foreach ($check in $checks) {
        $command = $check.Command
        $list = $check.List
        $selector = $check.Item ?? '@'
        # map preserves null items (a field projection would silently drop them).
        $query = '{kind:type(' + $list + '),items:map(&' + $selector + ',not_null(' + $list +
            ',`[]`)),empty:length(keys(@)) == `0`,pagination:[NextToken,nextToken,Marker,NextMarker,PaginationToken,ContinuationToken,NextContinuationToken,IsTruncated]}'
        $arguments = @($command.Split(' ')) + ($check.Options ?? @()) + @('--query', $query)
        try {
            $raw = & $ReadAws $arguments
            if ($raw -isnot [string] -or [string]::IsNullOrWhiteSpace($raw)) { throw 'Missing JSON' }
            $page = ConvertFrom-Json -InputObject $raw -AsHashtable -NoEnumerate -Depth 12 -ErrorAction Stop
            if ($page -isnot [System.Collections.IDictionary] -or $page.empty -isnot [bool] -or
                $page.items -isnot [array] -or $page.pagination -isnot [array] -or $page.pagination.Count -ne 8) {
                throw 'Malformed inventory'
            }
            # SQS omits QueueUrls and returns an empty object when no queues exist.
            $emptySqs = $list -eq 'QueueUrls' -and $page.empty -and $page.kind -ceq 'null' -and $page.items.Count -eq 0
            if (-not $emptySqs -and ($page.kind -cne 'array' -or $page.empty)) { throw 'Unexpected collection' }
            foreach ($token in $page.pagination) {
                if ($null -ne $token -and -not ($token -is [string] -and $token.Length -eq 0) -and
                    -not ($token -is [bool] -and !$token)) { throw 'Incomplete page' }
            }
        } catch {
            throw "First review stopped: unreadable, incomplete or unexpected inventory for '$command'."
        }
        foreach ($item in $page.items) {
            if ($list -eq 'Vpcs') {
                try {
                    if ($item -isnot [System.Collections.IDictionary] -or $item.primary -isnot [string] -or
                        $item.associations -isnot [array] -or !$item.associations.Count) { throw 'Incomplete VPC' }
                    $ranges = @($item.primary)
                    foreach ($association in $item.associations) {
                        if ($association.state -cnotin @('associated','associating','disassociating','disassociated','failing','failed') -or
                            $association.cidr -isnot [string]) { throw 'Incomplete association' }
                        if ($association.state -cne 'disassociated') { $ranges += $association.cidr }
                    }
                    $overlap = $false
                    foreach ($cidr in $ranges) {
                        if ($cidr -cnotmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$') { throw 'Invalid IPv4 CIDR' }
                        $network = [System.Net.IPNetwork]::Parse($cidr)
                        if ($development.Contains($network.BaseAddress) -or $network.Contains($development.BaseAddress)) { $overlap = $true }
                    }
                } catch {
                    throw 'First review stopped: VPC IPv4 associations could not be verified.'
                }
                if ($overlap) { throw 'First review stopped: the development CIDR overlaps an existing VPC.' }
            } else {
                if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
                    throw "First review stopped: unrecognized resource in '$command'."
                }
                if (($list -eq 'Buckets' -and $item -ceq $sourceArchiveBucket) -or
                    ($list -eq 'ResourceTagMappingList' -and $item -ceq "arn:aws:s3:::$sourceArchiveBucket")) { continue }
                if ($list -eq 'ResourceTagMappingList' -or $item -match 'vortex[-_]?bird|(?:^|[/:-])vb-(?:ecs|id)-') {
                    throw "First review stopped: a project resource or naming collision was found in '$command'. Verify its state before planning."
                }
            }
        }
    }
}
