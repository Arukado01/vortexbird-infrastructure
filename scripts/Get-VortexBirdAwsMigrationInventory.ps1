#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Profile = 'pge-deploy',
    [ValidatePattern('^[a-z]{2}(?:-[a-z]+)+-\d+$')]
    [string]$Region = 'us-east-2',
    [string[]]$TerraformStatePath = @(),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$account = '946876341107'
$portalHost = 'vortexbird.pgecolombia.com'
$poolId = 'us-east-2_nLop817zD'
$pgeVpc = 'vpc-06d2b54654435e52a'
$awsCli = (Get-Command aws -CommandType Application | Select-Object -First 1).Source
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$errors = [System.Collections.Generic.List[object]]::new()
$inventory = [System.Collections.Generic.List[object]]::new()
$stackBindings = @{}
$terraformBindings = @{}
$terraformDeclarations = [System.Collections.Generic.List[object]]::new()

function Read-Aws {
    param([string[]]$Arguments, [string]$Target, [switch]$Required)

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $command = $Arguments + @('--profile', $Profile, '--region', $Region, '--output', 'json', '--no-cli-pager', '--cli-connect-timeout', '5', '--cli-read-timeout', '10')
    $output = & $awsCli @command 2>&1
    $exitCode = $LASTEXITCODE
    $message = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) {
        $failure = [pscustomobject]@{ Arguments = $command; Target = $Target; ExitCode = $exitCode; Error = $message.Trim() }
        $errors.Add($failure)
        if ($Required) { throw ('aws {0}: {1}' -f ($command -join ' '), $failure.Error) }
        return
    }
    if (![string]::IsNullOrWhiteSpace($message)) { ConvertFrom-Json -InputObject $message -ErrorAction Stop }
}

function Test-ProtectedPge {
    param($Item)

    $identity = @($Item.Id, $Item.Name, $Item.Arn, $Item.Parent, $Item.VpcId) + @($Item.DependsOn)
    foreach ($value in $identity) {
        if ($value -eq $pgeVpc -or $value -match '(?i)(^|[:/])pge(?:[-/]|$)') { return $true }
    }
    $false
}

function Add-Inventory {
    param([string]$Kind, $Item)

    if (!$Item -or !$Item.Id) { return }
    $tags = @($Item.Tags | Where-Object {
        ($_.Key -in @('Project', 'Application', 'System') -and $_.Value -match '^(?i:vortex[-_ ]?bird|pge)$') -or
        $_.Key -in @('aws:cloudformation:stack-id', 'aws:cloudformation:stack-name', 'aws:cloudformation:logical-id')
    } | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Value = $_.Value } })
    $binding = $stackBindings[[string]$Item.Id]
    if (!$binding -and $Item.Arn) { $binding = $stackBindings[[string]$Item.Arn] }
    $terraform = $terraformBindings[[string]$Item.Id]
    if (!$terraform -and $Item.Arn) { $terraform = $terraformBindings[[string]$Item.Arn] }
    $isPge = (Test-ProtectedPge $Item) -or @($tags | Where-Object Value -eq 'pge').Count -gt 0
    $named = @($Item.Id, $Item.Arn, $Item.Name, $Item.Parent) -match '(?i)vortex[-_]?bird|(?:^|[:/])vb-(?:ecs|id)-'
    $projectTag = @($tags | Where-Object Value -match '^(?i:vortex[-_ ]?bird)$').Count -gt 0
    if (!$isPge -and !$named -and !$projectTag -and !$binding -and !$terraform -and $Item.Id -ne $poolId -and $Item.Parent -ne $poolId) { return }

    $disposition = 'RetainUntilOwnershipAndDependenciesVerified'
    if ($isPge) { $disposition = 'RetainPGE' }
    elseif ($Kind -in @('CognitoPool', 'CognitoClient', 'HostedZone', 'PortalDns') -or
        $Kind.StartsWith('AWS::Cognito::') -or $Kind.StartsWith('AWS::Route53::') -or
        $Item.Name -in @($portalHost, 'vortexbird-ohio-cognito') -or $Item.Id -eq $portalHost -or
        ($binding -and $binding.StackName -eq 'vortexbird-ohio-cognito')) {
        $disposition = 'RetainIdentityOrDomain'
    }
    elseif ($Kind -match '^(Rds|AWS::RDS::DB)') { $disposition = 'RetainUntilBackupAndRestoreVerified' }
    elseif ($binding -or $terraform -or $projectTag) { $disposition = 'ProjectCandidateReviewDependencies' }
    $inventory.Add([pscustomobject]@{
        Kind = $Kind; Id = $Item.Id; Name = $Item.Name; Arn = $Item.Arn; Created = $Item.Created
        Parent = $Item.Parent; VpcId = $Item.VpcId; Status = $Item.Status; DependsOn = @($Item.DependsOn | Where-Object { $_ })
        Engine = $Item.Engine; Database = $Item.Database; Public = $Item.Public; Tags = $tags
        CloudFormation = $binding; TerraformState = $terraform; Disposition = $disposition
    })
}

foreach ($directory in @('terraform', 'terraform-ecs')) {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) $directory
    foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Filter '*.tf' -ErrorAction SilentlyContinue)) {
        foreach ($declaration in @(Select-String -LiteralPath $file.FullName -Pattern '^\s*resource\s+"(?<type>aws_[a-z0-9_]+)"\s+"(?<name>[a-z0-9_-]+)"')) {
            $terraformDeclarations.Add([pscustomobject]@{
                File = "$directory/$($file.Name)"; Address = $declaration.Matches[0].Groups['type'].Value + '.' + $declaration.Matches[0].Groups['name'].Value
            })
        }
    }
}

foreach ($statePath in $TerraformStatePath) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    foreach ($resource in @($state.resources | Where-Object {
        $_.mode -eq 'managed' -and $_.type -match '^aws_' -and $_.type -notmatch '(?:secret_version|sensitive|access_key|login_profile|ssm_parameter)$'
    })) {
        foreach ($instance in @($resource.instances)) {
            $attributes = $instance.attributes
            foreach ($id in @($attributes.arn, $attributes.id) | Where-Object { $_ -is [string] -and $_ -match '^[a-zA-Z0-9:/_.+=,@-]{1,512}$' }) {
                $terraformBindings[$id] = [pscustomobject]@{ File = Split-Path -Leaf $statePath; Address = (@($resource.module, $resource.type, $resource.name) | Where-Object { $_ }) -join '.' }
            }
        }
    }
}

$identity = Read-Aws -Arguments @('sts', 'get-caller-identity') -Target $account -Required
if ($identity.Account -ne $account) { throw "Cuenta AWS inesperada: $($identity.Account). Se esperaba $account." }

$stacks = @(Read-Aws -Arguments @('cloudformation', 'list-stacks', '--query', 'StackSummaries[?StackStatus!=`DELETE_COMPLETE`].{Id:StackId,Name:StackName,Created:CreationTime,Status:StackStatus,Parent:ParentId}') -Target $Region)
$templatePaths = @{
    'vortexbird-pilot-web' = '.work/serverless-pilot/VortexBird_Public_Web_R1.json'
    'vortexbird-pilot-data' = '.work/serverless-pilot/VortexBird_Data_Lambda_v2.json'
    'vortexbird-pilot-portal' = '.work/serverless-pilot/VortexBird_Portal_Lambda.json'
    'vortexbird-pilot-runtime' = '.work/serverless-pilot/VortexBird_Runtime_Container.json'
    'vortexbird-ohio-cognito' = '.work/serverless-pilot/VortexBird_Cognito_Native_5d7bb29873cc.json'
    'vortexbird-ohio-foundation' = '.work/aws-ohio-live/VortexBird_Ohio_Foundation.json'
    'vortexbird-ohio-roles' = '.work/aws-ohio-live/VortexBird_Ohio_Roles.json'
}
$stackResources = [System.Collections.Generic.List[object]]::new()
foreach ($stack in @($stacks | Where-Object Name -match '^vortexbird-')) {
    $relativePath = $templatePaths[[string]$stack.Name]
    $template = $null
    if ($relativePath) {
        $templatePath = Join-Path $workspace $relativePath
        if (Test-Path -LiteralPath $templatePath -PathType Leaf) { $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json }
    }
    $resources = @(Read-Aws -Arguments @('cloudformation', 'list-stack-resources', '--stack-name', $stack.Id, '--query', 'StackResourceSummaries[?ResourceStatus!=`DELETE_COMPLETE` && PhysicalResourceId!=`null`].{Id:PhysicalResourceId,LogicalId:LogicalResourceId,Kind:ResourceType,Status:ResourceStatus}') -Target $stack.Id)
    foreach ($resource in $resources) {
        if (!$resource.Id) { continue }
        $matchesTemplate = $false
        if ($template) {
            $definition = $template.Resources.PSObject.Properties[$resource.LogicalId]
            $matchesTemplate = $definition -and $definition.Value.Type -eq $resource.Kind
        }
        $stackBindings[[string]$resource.Id] = [pscustomobject]@{
            StackName = $stack.Name; StackId = $stack.Id; LogicalId = $resource.LogicalId; Type = $resource.Kind
            LocalTemplate = $(if ($matchesTemplate) { $relativePath }); TemplateMatch = [bool]$matchesTemplate
        }
        if ($matchesTemplate -and !$stackBindings[[string]$stack.Id]) {
            $stackBindings[[string]$stack.Id] = [pscustomobject]@{
                StackName = $stack.Name; StackId = $stack.Id; LocalTemplate = $relativePath; TemplateMatch = $true
            }
        }
        $stackResources.Add([pscustomobject]@{ Kind = $resource.Kind; Id = $resource.Id; Name = $resource.LogicalId; Status = $resource.Status; Parent = $stack.Name })
    }
}
foreach ($stack in $stacks) { Add-Inventory 'CloudFormationStack' $stack }
foreach ($resource in $stackResources) { Add-Inventory $resource.Kind $resource }

$scans = @(
    @('EcsCluster', 'ecs', 'list-clusters', 'clusterArns[].{Id:@,Arn:@}'),
    @('EcrRepository', 'ecr', 'describe-repositories', 'repositories[].{Id:repositoryName,Name:repositoryName,Arn:repositoryArn,Created:createdAt}'),
    @('LoadBalancer', 'elbv2', 'describe-load-balancers', 'LoadBalancers[].{Id:LoadBalancerArn,Arn:LoadBalancerArn,Name:LoadBalancerName,VpcId:VpcId,Created:CreatedTime,Status:State.Code,DependsOn:SecurityGroups}'),
    @('TargetGroup', 'elbv2', 'describe-target-groups', 'TargetGroups[].{Id:TargetGroupArn,Arn:TargetGroupArn,Name:TargetGroupName,VpcId:VpcId,DependsOn:LoadBalancerArns}'),
    @('Vpc', 'ec2', 'describe-vpcs', 'Vpcs[].{Id:VpcId,VpcId:VpcId,Tags:Tags,Status:State,Name:Tags[?Key==`Name`].Value|[0]}'),
    @('Subnet', 'ec2', 'describe-subnets', 'Subnets[].{Id:SubnetId,VpcId:VpcId,Tags:Tags,Status:State,Name:Tags[?Key==`Name`].Value|[0],Public:MapPublicIpOnLaunch}'),
    @('SecurityGroup', 'ec2', 'describe-security-groups', 'SecurityGroups[].{Id:GroupId,VpcId:VpcId,Tags:Tags,Name:GroupName}'),
    @('RouteTable', 'ec2', 'describe-route-tables', 'RouteTables[].{Id:RouteTableId,VpcId:VpcId,Tags:Tags,Name:Tags[?Key==`Name`].Value|[0],DependsOn:Associations[].SubnetId}'),
    @('VpcEndpoint', 'ec2', 'describe-vpc-endpoints', 'VpcEndpoints[].{Id:VpcEndpointId,VpcId:VpcId,Tags:Tags,Name:Tags[?Key==`Name`].Value|[0],Created:CreationTimestamp,Status:State,DependsOn:SubnetIds}'),
    @('NetworkInterface', 'ec2', 'describe-network-interfaces', 'NetworkInterfaces[].{Id:NetworkInterfaceId,VpcId:VpcId,Tags:TagSet,Parent:Attachment.InstanceId,Status:Status,DependsOn:Groups[].GroupId}'),
    @('InternetGateway', 'ec2', 'describe-internet-gateways', 'InternetGateways[].{Id:InternetGatewayId,VpcId:Attachments[0].VpcId,Tags:Tags,Name:Tags[?Key==`Name`].Value|[0],DependsOn:Attachments[].VpcId}'),
    @('NatGateway', 'ec2', 'describe-nat-gateways', 'NatGateways[].{Id:NatGatewayId,VpcId:VpcId,Tags:Tags,Created:CreateTime,Status:State,Name:Tags[?Key==`Name`].Value|[0],DependsOn:[SubnetId]}'),
    @('ElasticIp', 'ec2', 'describe-addresses', 'Addresses[].{Id:AllocationId,Tags:Tags,Parent:InstanceId,DependsOn:[NetworkInterfaceId]}'),
    @('Ec2Instance', 'ec2', 'describe-instances', 'Reservations[].Instances[].{Id:InstanceId,VpcId:VpcId,Tags:Tags,Created:LaunchTime,Status:State.Name,Name:Tags[?Key==`Name`].Value|[0],DependsOn:SecurityGroups[].GroupId}'),
    @('RdsInstance', 'rds', 'describe-db-instances', 'DBInstances[].{Id:DBInstanceIdentifier,Name:DBInstanceIdentifier,Arn:DBInstanceArn,VpcId:DBSubnetGroup.VpcId,Tags:TagList,Created:InstanceCreateTime,Status:DBInstanceStatus,Engine:Engine,Database:DBName,Public:PubliclyAccessible,DependsOn:VpcSecurityGroups[].VpcSecurityGroupId}'),
    @('RdsCluster', 'rds', 'describe-db-clusters', 'DBClusters[].{Id:DBClusterIdentifier,Name:DBClusterIdentifier,Arn:DBClusterArn,Tags:TagList,Created:ClusterCreateTime,Status:Status,Engine:Engine,Database:DatabaseName,DependsOn:DBClusterMembers[].DBInstanceIdentifier}'),
    @('RdsSnapshot', 'rds', 'describe-db-snapshots', 'DBSnapshots[].{Id:DBSnapshotIdentifier,Name:DBSnapshotIdentifier,Arn:DBSnapshotArn,Tags:TagList,Created:SnapshotCreateTime,Status:Status,Engine:Engine,Parent:DBInstanceIdentifier}'),
    @('SecretMetadata', 'secretsmanager', 'list-secrets', 'SecretList[].{Id:Name,Name:Name,Arn:ARN,Tags:Tags,Created:CreatedDate,Status:DeletedDate}'),
    @('ParameterMetadata', 'ssm', 'describe-parameters', 'Parameters[].{Id:Name,Name:Name}'),
    @('SqsQueue', 'sqs', 'list-queues', 'QueueUrls[].{Id:@}'),
    @('LogGroup', 'logs', 'describe-log-groups', 'logGroups[].{Id:logGroupName,Name:logGroupName,Arn:arn,Created:creationTime}'),
    @('Bucket', 's3api', 'list-buckets', 'Buckets[].{Id:Name,Name:Name,Created:CreationDate}'),
    @('CloudFront', 'cloudfront', 'list-distributions', 'DistributionList.Items[].{Id:Id,Arn:ARN,Name:Aliases.Items[0],Status:Status,DependsOn:Origins.Items[].DomainName}'),
    @('IamRole', 'iam', 'list-roles', 'Roles[].{Id:RoleName,Name:RoleName,Arn:Arn,Created:CreateDate,Tags:Tags}'),
    @('IamPolicy', 'iam', 'list-policies', 'Policies[].{Id:Arn,Name:PolicyName,Arn:Arn,Created:CreateDate}'),
    @('ApiGatewayRest', 'apigateway', 'get-rest-apis', 'items[].{Id:id,Name:name,Created:createdDate,Tags:tags}'),
    @('ApiGatewayDomain', 'apigateway', 'get-domain-names', 'items[].{Id:domainName,Name:domainName,Status:domainNameStatus,DependsOn:[regionalCertificateArn,certificateArn,regionalDomainName,distributionDomainName]}'),
    @('AcmCertificate', 'acm', 'list-certificates', 'CertificateSummaryList[].{Id:CertificateArn,Arn:CertificateArn,Name:DomainName,Created:CreatedAt,Status:Status}'),
    @('HostedZone', 'route53', 'list-hosted-zones', 'HostedZones[?Name==`vortexbird.pgecolombia.com.` || Name==`pgecolombia.com.`].{Id:Id,Name:Name,Parent:`vortexbird.pgecolombia.com`}')
)
foreach ($scan in $scans) {
    $arguments = @($scan[1], $scan[2], '--query', $scan[3])
    if ($scan[0] -eq 'IamPolicy') { $arguments += @('--scope', 'Local') }
    if ($scan[0] -eq 'SqsQueue') { $arguments += @('--page-size', '1000') }
    foreach ($item in @(Read-Aws -Arguments $arguments -Target $Region)) {
        if ($item.Tags -is [pscustomobject]) {
            $item.Tags = @($item.Tags.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = $_.Value } })
        }
        Add-Inventory $scan[0] $item
    }
}

foreach ($status in @('ACTIVE', 'INACTIVE')) {
    foreach ($definition in @(Read-Aws -Arguments @('ecs', 'list-task-definitions', '--status', $status, '--query', 'taskDefinitionArns[].{Id:@,Arn:@}') -Target $Region)) {
        $definition | Add-Member -NotePropertyName Status -NotePropertyValue $status
        Add-Inventory 'EcsTaskDefinition' $definition
    }
}
foreach ($cluster in @($inventory | Where-Object Kind -eq 'EcsCluster')) {
    $services = @(Read-Aws -Arguments @('ecs', 'list-services', '--cluster', $cluster.Id, '--query', 'serviceArns') -Target $cluster.Id)
    for ($index = 0; $index -lt $services.Count; $index += 10) {
        $last = [Math]::Min($index + 9, $services.Count - 1)
        $arguments = @('ecs', 'describe-services', '--cluster', $cluster.Id, '--include', 'TAGS', '--query', 'services[].{Id:serviceArn,Arn:serviceArn,Name:serviceName,Parent:clusterArn,Created:createdAt,Status:status,Tags:tags,DependsOn:[taskDefinition,loadBalancers[].targetGroupArn][]}', '--services') + $services[$index..$last]
        foreach ($service in @(Read-Aws -Arguments $arguments -Target $cluster.Id)) { Add-Inventory 'EcsService' $service }
    }
}
foreach ($repository in @($inventory | Where-Object { $_.Kind -eq 'EcrRepository' -and $_.Disposition -ne 'RetainPGE' })) {
    foreach ($image in @(Read-Aws -Arguments @('ecr', 'describe-images', '--repository-name', $repository.Name, '--query', 'imageDetails[].{Id:imageDigest,Created:imagePushedAt,DependsOn:imageTags}') -Target $repository.Arn)) {
        $image | Add-Member -NotePropertyName Parent -NotePropertyValue $repository.Name
        Add-Inventory 'EcrImage' $image
    }
}
foreach ($loadBalancer in @($inventory | Where-Object { $_.Kind -eq 'LoadBalancer' -and $_.Disposition -ne 'RetainPGE' })) {
    foreach ($listener in @(Read-Aws -Arguments @('elbv2', 'describe-listeners', '--load-balancer-arn', $loadBalancer.Arn, '--query', 'Listeners[].{Id:ListenerArn,Arn:ListenerArn,Parent:LoadBalancerArn,DependsOn:[DefaultActions[].TargetGroupArn,Certificates[].CertificateArn][]}') -Target $loadBalancer.Arn)) {
        Add-Inventory 'LoadBalancerListener' $listener
    }
}
foreach ($zone in @($inventory | Where-Object Kind -eq 'HostedZone')) {
    $query = "ResourceRecordSets[?Name=='${portalHost}.' && (Type=='A' || Type=='AAAA' || Type=='CNAME' || Type=='NS' || Type=='SOA')].{Id:join('/',[Name,Type]),Name:Name,Status:Type,DependsOn:[AliasTarget.DNSName,ResourceRecords[].Value][]}"
    $zoneId = $zone.Id -replace '^/hostedzone/', ''
    foreach ($record in @(Read-Aws -Arguments @('route53', 'list-resource-record-sets', '--hosted-zone-id', $zoneId, '--query', $query) -Target $zone.Id)) {
        $record | Add-Member -NotePropertyName Parent -NotePropertyValue $zone.Id
        Add-Inventory 'PortalDns' $record
    }
}
$userCount = $null
if ($Region -eq 'us-east-2') {
    $pool = Read-Aws -Arguments @('cognito-idp', 'describe-user-pool', '--user-pool-id', $poolId, '--query', 'UserPool.{Id:Id,Arn:Arn,Name:Name,Created:CreationDate}') -Target $poolId
    Add-Inventory 'CognitoPool' $pool
    if ($pool) {
        foreach ($client in @(Read-Aws -Arguments @('cognito-idp', 'list-user-pool-clients', '--user-pool-id', $poolId, '--max-results', '60', '--query', 'UserPoolClients[].{Id:ClientId,Name:ClientName}') -Target $poolId)) {
            $client | Add-Member -NotePropertyName Parent -NotePropertyValue $poolId
            Add-Inventory 'CognitoClient' $client
        }
        $userCount = Read-Aws -Arguments @('cognito-idp', 'list-users', '--user-pool-id', $poolId, '--query', 'length(Users)') -Target $poolId
    }
}

$report = [ordered]@{
    CapturedUtc = [DateTime]::UtcNow.ToString('o'); ReadOnly = $true; Account = $identity.Account; Principal = $identity.Arn
    Profile = $Profile; Region = $Region; Complete = ($errors.Count -eq 0); CognitoUserCount = $userCount
    Inventory = @($inventory.ToArray() | Sort-Object Kind, Id); TerraformDeclarations = $terraformDeclarations.ToArray()
    TerraformStateFiles = @($TerraformStatePath | ForEach-Object { Split-Path -Leaf $_ }); Errors = $errors.ToArray()
}
$json = ConvertTo-Json -InputObject $report -Depth 12
if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8 } else { $json }
if ($errors.Count) { throw 'Inventario incompleto. Revisa Errors y repite las consultas fallidas antes de decidir qué recursos se pueden retirar.' }
