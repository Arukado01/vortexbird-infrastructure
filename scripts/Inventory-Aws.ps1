param([string]$Profile = 'default', [string]$Region = 'us-east-2')
$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''
$infraRoot = Split-Path $PSScriptRoot -Parent
$outputPath = Join-Path $infraRoot 'reports'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$identity = aws sts get-caller-identity --profile $Profile --region $Region --output json 2>&1
if ($LASTEXITCODE -ne 0) { throw 'AWS identity could not be verified. Inventory stopped; no account assumed.' }
$identity | Set-Content -LiteralPath (Join-Path $outputPath 'identity.json')
$queries = @(
  @{ Name='regions'; Args=@('ec2','describe-regions','--query','Regions[].{Name:RegionName,Status:OptInStatus}') },
  @{ Name='vpcs'; Args=@('ec2','describe-vpcs','--query','Vpcs[].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault}') },
  @{ Name='eks'; Args=@('eks','list-clusters') },
  @{ Name='rds'; Args=@('rds','describe-db-instances','--query','DBInstances[].{Id:DBInstanceIdentifier,Class:DBInstanceClass,MultiAZ:MultiAZ,Public:PubliclyAccessible}') },
  @{ Name='redis'; Args=@('elasticache','describe-replication-groups','--query','ReplicationGroups[].{Id:ReplicationGroupId,Status:Status}') },
  @{ Name='queues'; Args=@('sqs','list-queues') },
  @{ Name='loadbalancers'; Args=@('elbv2','describe-load-balancers','--query','LoadBalancers[].{Name:LoadBalancerName,Scheme:Scheme,Type:Type}') },
  @{ Name='ecr'; Args=@('ecr','describe-repositories','--query','repositories[].{Name:repositoryName,Mutable:imageTagMutability}') }
)
foreach ($query in $queries) {
  $argsList = $query.Args + @('--profile',$Profile,'--region',$Region,'--output','json')
  $result = & aws @argsList 2>&1
  if ($LASTEXITCODE -eq 0) { $result | Set-Content -LiteralPath (Join-Path $outputPath ($query.Name + '.json')) }
  else { Write-Warning ('Unable to read ' + $query.Name + '; inventory incomplete.') }
}
Write-Output 'Read-only inventory completed. Reports contain account metadata; keep out of Git.'
