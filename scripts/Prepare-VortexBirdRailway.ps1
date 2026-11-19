#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Provision', 'Deploy')]
    [string] $Phase = 'Inspect',
    [guid] $ProjectId = [guid]::Empty,
    [guid] $WorkspaceId = [guid]::Empty,
    [guid] $ExpectedEnvironmentId = [guid]::Empty,
    [switch] $NoSourceDatabase,
    [string] $AwsProfile = 'pge-deploy',
    [string] $RailwayCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not $RailwayCli) {
    $command = Get-Command railway.exe, railway.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'Railway CLI is missing from PATH. Install @railway/cli and sign in from this Windows session.' }
    $RailwayCli = $command.Source
}

function Invoke-Railway([string[]] $Arguments) {
    # Native CLI progress stays on stderr, including successful `init --json` runs.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $RailwayCli @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Railway CLI exit $LASTEXITCODE for: railway $($Arguments -join ' ')"
    }
    return $output
}

function Invoke-RailwayApi([string] $Document, [string[]] $Variables = @()) {
    $output = Invoke-Railway (@('api', '--compact', $Document) + $Variables)
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'data') { return $result.data }
    return $result
}

function Invoke-RailwayJson([string[]] $Arguments, [switch] $Array) {
    $command = 'railway ' + ($Arguments -join ' ')
    $json = ((Invoke-Railway $Arguments) -join "`n").Trim()
    $opening = if ($Array) { '[' } else { '{' }
    if (-not $json.StartsWith($opening, [StringComparison]::Ordinal)) {
        throw "$command did not return the expected JSON. Verify the CLI connection and version."
    }
    try {
        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        throw "$command returned invalid JSON."
    }
    if ($Array) {
        if ($json -match '^\[\s*\]$') { return ,@() }
        if ($null -eq $parsed) { throw "$command returned an invalid JSON array." }
        return ,@($parsed)
    }
    return $parsed
}

function Read-RailwayId($Value, [string] $Field) {
    $id = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value, 'D', [ref] $id) -or $id -eq [guid]::Empty) {
        throw "Railway JSON contained an invalid $Field."
    }
    return $id
}

function Get-RailwayTarget {
    $identity = Invoke-RailwayJson @('whoami', '--json')
    if (-not $identity.PSObject.Properties['email'] -or $identity.email -isnot [string] -or
        [string]::IsNullOrWhiteSpace($identity.email) -or -not $identity.PSObject.Properties['workspaces'] -or
        $identity.workspaces -isnot [array]) {
        throw 'railway whoami --json did not return an authenticated identity with a workspaces array.'
    }
    $workspaces = @{}
    foreach ($workspaceInfo in $identity.workspaces) {
        if ($null -eq $workspaceInfo -or -not $workspaceInfo.PSObject.Properties['id'] -or
            -not $workspaceInfo.PSObject.Properties['name'] -or $workspaceInfo.name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($workspaceInfo.name)) {
            throw 'railway whoami --json returned a workspace without an ID or name.'
        }
        $id = Read-RailwayId $workspaceInfo.id 'workspace ID from railway whoami --json'
        if ($workspaces.ContainsKey($id)) { throw "railway whoami --json returned workspace $id more than once." }
        $workspaces[$id] = $workspaceInfo.name
    }
    if ($workspaces.Count -eq 0) { throw 'The authenticated Railway account has no accessible workspaces.' }
    if ($WorkspaceId -ne [guid]::Empty -and -not $workspaces.ContainsKey($WorkspaceId)) {
        throw "Workspace $WorkspaceId is not accessible to the authenticated Railway account."
    }

    $projects = Invoke-RailwayJson @('list', '--json') -Array
    $seenProjects = @{}
    $matches = @(foreach ($project in $projects) {
        if ($null -eq $project -or -not $project.PSObject.Properties['id'] -or
            -not $project.PSObject.Properties['name'] -or $project.name -isnot [string] -or
            [string]::IsNullOrWhiteSpace($project.name) -or -not $project.PSObject.Properties['workspace'] -or
            $null -eq $project.workspace -or -not $project.workspace.PSObject.Properties['id']) {
            throw 'railway list --json returned a project without an ID, name or workspace ID.'
        }
        $id = Read-RailwayId $project.id 'project ID from railway list --json'
        $owner = Read-RailwayId $project.workspace.id 'workspace ID from railway list --json'
        if (-not $workspaces.ContainsKey($owner) -or $seenProjects.ContainsKey($id)) {
            throw 'railway list --json returned an unknown workspace or duplicate project ID. Retry the inventory before provisioning.'
        }
        $seenProjects[$id] = $true
        if ($project.name -ieq 'VortexBird' -and ($WorkspaceId -eq [guid]::Empty -or $owner -eq $WorkspaceId) -and
            ($ProjectId -eq [guid]::Empty -or $id -eq $ProjectId)) {
            [pscustomobject] @{ ProjectId = $id; WorkspaceId = $owner; WorkspaceName = $workspaces[$owner] }
        }
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) {
        $choices = ($matches | ForEach-Object { "$($_.WorkspaceName) ($($_.WorkspaceId)), project $($_.ProjectId)" }) -join '; '
        throw "Multiple VortexBird projects match. Specify -WorkspaceId or -ProjectId. Matches: $choices"
    }
    if ($ProjectId -ne [guid]::Empty) {
        throw "Project $ProjectId is not an accessible VortexBird project in the selected workspace."
    }
    $target = $WorkspaceId
    if ($target -eq [guid]::Empty) {
        if ($workspaces.Count -gt 1) {
            $choices = ($workspaces.GetEnumerator() | Sort-Object Value | ForEach-Object { "$($_.Value) ($($_.Key))" }) -join '; '
            throw "VortexBird was not found. Specify -WorkspaceId to select where to create it. Workspaces: $choices"
        }
        $target = @($workspaces.Keys)[0]
    }
    return [pscustomobject] @{ ProjectId = $null; WorkspaceId = $target; WorkspaceName = $workspaces[$target] }
}

function Get-Project([string] $Id) {
    $data = Invoke-RailwayApi 'query ($id: String!) { project(id: $id) { id name workspaceId services { edges { node { id name } } } environments { edges { node { id name } } } } }' @('--raw-var', "id=$Id")
    if ($null -eq $data.project -or $data.project.id -ne $Id -or $data.project.name -ine 'VortexBird') { throw 'The selected project is not VortexBird.' }
    if ($data.project.workspaceId -ne $target.WorkspaceId.ToString()) { throw 'VortexBird is not in the verified workspace.' }
    return $data.project
}

function Get-Services([object] $Project) {
    $services = @{}
    foreach ($edge in $Project.services.edges) {
        $service = $edge.node
        if ($services.ContainsKey($service.name)) { throw "Ambiguous service name: $($service.name)" }
        $services[$service.name] = [string] $service.id
    }
    return $services
}

function Set-RailwayVariable([string] $ServiceId, [string] $Name, [object] $Value) {
    $arguments = @('variable', 'set', '--service', $ServiceId, '--environment', $environmentId, '--project', $projectIdValue, '--skip-deploys', '--stdin', $Name)
    $text = if ($Value -is [securestring]) { [Net.NetworkCredential]::new('', $Value).Password } else { [string] $Value }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    $null = $text | & $RailwayCli @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Railway CLI exit $LASTEXITCODE setting $Name for service $ServiceId." }
}

function Get-Deployment([string] $ServiceId) {
    $query = 'query ($serviceId: String!, $environmentId: String!) { serviceInstance(serviceId: $serviceId, environmentId: $environmentId) { latestDeployment { id status } } }'
    $data = Invoke-RailwayApi $query @('--raw-var', "serviceId=$ServiceId", '--raw-var', "environmentId=$environmentId")
    if ($data.serviceInstance) { return $data.serviceInstance.latestDeployment }
}

function Publish-Service([string] $ServiceId, [string] $Source) {
    $previous = Get-Deployment $ServiceId
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path
    Write-Host "Uploading $sourceRoot to Railway service $ServiceId"
    Invoke-Railway @('up', $sourceRoot, '--path-as-root', '--project', $projectIdValue, '--environment', $environmentId, '--service', $ServiceId, '--ci') | Out-Host
    $deadline = [datetime]::UtcNow.AddMinutes(20)
    do {
        Start-Sleep -Seconds 8
        $deployment = Get-Deployment $ServiceId
        if ($deployment -and (-not $previous -or $deployment.id -ne $previous.id)) {
            if ($deployment.status -in @('FAILED', 'CRASHED', 'REMOVED', 'SKIPPED', 'CANCELED')) {
                throw "Railway deployment $($deployment.id) for $ServiceId is $($deployment.status). Inspect railway logs $($deployment.id) --lines 80."
            }
            if ($deployment.status -eq 'SUCCESS') { return $deployment.id }
        }
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out verifying the new Railway deployment for $ServiceId."
}

function Set-Healthcheck([string] $ServiceId, [string] $Path, [switch] $AlwaysOn) {
    $additionalSettings = if ($AlwaysOn) { ', sleepApplication: false' } else { '' }
    $mutation = 'mutation ($serviceId: String!, $environmentId: String!, $path: String!) { serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: { healthcheckPath: $path, healthcheckTimeout: 180' + $additionalSettings + ' }) }'
    $result = Invoke-RailwayApi $mutation @('--raw-var', "serviceId=$ServiceId", '--raw-var', "environmentId=$environmentId", '--raw-var', "path=$Path")
    if ($result.serviceInstanceUpdate -ne $true) { throw "Railway did not set the health check for $ServiceId." }
}

function Assert-ServiceInEnvironment([string] $ServiceId) {
    $query = 'query ($serviceId: String!, $environmentId: String!) { serviceInstance(serviceId: $serviceId, environmentId: $environmentId) { id } }'
    if (-not $ServiceId) { throw 'Expected a verified Railway service ID.' }
    $data = Invoke-RailwayApi $query @('--raw-var', "serviceId=$ServiceId", '--raw-var', "environmentId=$environmentId")
    if (-not $data.serviceInstance) { throw "Railway service $ServiceId does not exist in the selected environment." }
}

function Assert-PrivateService([string] $ServiceId, [string] $Name) {
    $selectors = @('--raw-var', "projectId=$projectIdValue", '--raw-var', "environmentId=$environmentId", '--raw-var', "serviceId=$ServiceId")
    $query = 'query ($projectId: String!, $environmentId: String!, $serviceId: String!) { domains(projectId: $projectId, environmentId: $environmentId, serviceId: $serviceId) { serviceDomains { id } customDomains { id } } tcpProxies(serviceId: $serviceId, environmentId: $environmentId) { id } }'
    $network = Invoke-RailwayApi $query $selectors
    if (@($network.domains.serviceDomains).Count -or @($network.domains.customDomains).Count -or @($network.tcpProxies).Count) {
        throw "$Name must have no public HTTP domains or TCP proxy before the database migration."
    }
}

function Get-ServiceDomain([string] $ServiceId, [switch] $Create) {
    $query = 'query ($projectId: String!, $environmentId: String!, $serviceId: String!) { domains(projectId: $projectId, environmentId: $environmentId, serviceId: $serviceId) { serviceDomains { domain targetPort } } }'
    $selectors = @('--raw-var', "projectId=$projectIdValue", '--raw-var', "environmentId=$environmentId", '--raw-var', "serviceId=$ServiceId")
    $domains = @((Invoke-RailwayApi $query $selectors).domains.serviceDomains)
    if ($domains.Count -eq 0) {
        if (-not $Create) { return $null }
        $null = Invoke-Railway @('domain', '--service', $ServiceId, '--environment', $environmentId, '--project', $projectIdValue, '--port', '8080', '--json')
        $domains = @((Invoke-RailwayApi $query $selectors).domains.serviceDomains)
    }
    if ($domains.Count -ne 1 -or $domains[0].domain -notmatch '^[a-zA-Z0-9-]+\.up\.railway\.app$' -or
        ($null -ne $domains[0].targetPort -and $domains[0].targetPort -ne 8080)) {
        throw "No unique generated Railway domain could be verified for service $ServiceId."
    }
    return 'https://' + $domains[0].domain
}

function Assert-NoSourceDatabase {
    if ($NoSourceDatabase) {
        Write-Host 'Source PostgreSQL absence was explicitly verified by the caller.'
        return
    }
    $aws = (Get-Command aws -CommandType Application -ErrorAction Stop).Source
    $arguments = @('rds', 'describe-db-instances', '--profile', $AwsProfile, '--region', 'us-east-2', '--no-cli-pager', '--output', 'json', '--cli-connect-timeout', '5', '--cli-read-timeout', '10', '--query', 'DBInstances[].{Id:DBInstanceIdentifier,Database:DBName,Tags:TagList}')
    $result = & $aws @arguments
    if ($LASTEXITCODE -ne 0) { throw 'AWS CLI could not verify whether an Ohio VortexBird PostgreSQL source exists.' }
    $text = ($result -join "`n").Trim()
    if (-not $text.StartsWith('[')) { throw 'AWS CLI did not return the expected RDS inventory array.' }
    $instances = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    $candidates = @($instances | Where-Object {
        $_ -and ((@($_.Id, $_.Database) -join ' ') -match 'vortexbird|(^|[-_ ])vb[-_ ]' -or
        @($_.Tags | Where-Object { $_ -and $_.Value -match 'vortexbird' }).Count -gt 0)
    })
    if ($candidates.Count -gt 0) {
        throw "Existing VortexBird PostgreSQL candidate(s) require verified backup and restore: $($candidates.Id -join ', ')."
    }
    Write-Host 'Ohio RDS inventory contains no VortexBird PostgreSQL source.'
}

function New-DatabaseReference([securestring] $Connection) {
    $url = [uri] ([Net.NetworkCredential]::new('', $Connection).Password)
    if ($url.Scheme -notin @('postgresql', 'postgres') -or $url.Host -notlike '*.railway.internal' -or
        -not $url.UserInfo -or $url.AbsolutePath -cne '/vortexbird_app') {
        throw 'The database role does not identify the verified private VortexBird database.'
    }
    return ('postgresql://' + $url.UserInfo + '@${{vortexbird-postgres.PGHOST}}:${{vortexbird-postgres.PGPORT}}' + $url.AbsolutePath)
}

function Set-WorkerMigration([string] $ServiceId, [switch] $Enable, [switch] $ValidateOnly) {
    $command = 'dotnet VortexBird.API.dll --migrate --bind-pilot-roles'
    $selectors = @('--raw-var', "serviceId=$ServiceId", '--raw-var', "environmentId=$environmentId")
    $read = 'query ($serviceId: String!, $environmentId: String!) { serviceInstance(serviceId: $serviceId, environmentId: $environmentId) { preDeployCommand } }'
    $current = (Invoke-RailwayApi $read $selectors).serviceInstance.preDeployCommand
    $currentCommands = @($current)
    if ($current -and ($currentCommands.Count -ne 1 -or $currentCommands[0] -cne $command)) {
        throw 'The worker has an unrelated pre-deploy command. Preserve it and review the existing configuration.'
    }
    if ($ValidateOnly) { return }
    $commands = if ($Enable) { '[$command]' } else { '[]' }
    $declaration = if ($Enable) { ', $command: String!' } else { '' }
    $mutation = 'mutation ($serviceId: String!, $environmentId: String!' + $declaration + ') { serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: { preDeployCommand: ' + $commands + ' }) }'
    if ($Enable) { $selectors += @('--raw-var', "command=$command") }
    if ((Invoke-RailwayApi $mutation $selectors).serviceInstanceUpdate -ne $true) {
        throw 'Railway did not save the worker migration command.'
    }
    $saved = (Invoke-RailwayApi $read @('--raw-var', "serviceId=$ServiceId", '--raw-var', "environmentId=$environmentId")).serviceInstance.preDeployCommand
    if (($Enable -and (@($saved).Count -ne 1 -or @($saved)[0] -cne $command)) -or (-not $Enable -and $saved)) {
        throw 'The worker migration command could not be verified after the update.'
    }
}

function Confirm-DatabaseMigration([string] $DeploymentId, [string] $ServiceId) {
    # Railway can preserve the application JSON in message or extract its fields into the log record.
    $readFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($type in @('--deployment', '--build')) {
        try {
            $lines = Invoke-Railway @('logs', $DeploymentId, '--service', $ServiceId, '--project', $projectIdValue, '--environment', $environmentId, $type, '--json', '--lines', '200')
        }
        catch { $readFailures.Add($type); continue }
        foreach ($line in $lines) {
            if (-not $line.TrimStart().StartsWith('{')) { continue }
            $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            $event = $record
            if ($record.PSObject.Properties['message'] -and $record.message -is [string] -and
                $record.message.TrimStart().StartsWith('{"operation":')) {
                $event = ConvertFrom-Json -InputObject $record.message -ErrorAction Stop
            }
            if ($event.PSObject.Properties['operation'] -and $event.operation -ceq 'database_deployment' -and
                $event.PSObject.Properties['status'] -and $event.status -ceq 'completed' -and
                $event.PSObject.Properties['migrations'] -and "$($event.migrations)" -ieq 'true' -and
                $event.PSObject.Properties['cognitoBindings'] -and "$($event.cognitoBindings)" -ceq '9') {
                return
            }
        }
    }
    $detail = if ($readFailures.Count) { " Log streams unavailable: $($readFailures -join ', ')." } else { '' }
    throw "Deployment $DeploymentId did not report successful EF migrations and nine Cognito bindings.$detail"
}

function Invoke-PrivateWorkerMigration([string] $WorkerId, [string] $Backend, [System.Collections.IDictionary] $JobVariables) {
    $migration = $null
    $worker = $null
    $startingDeployment = Get-Deployment $WorkerId
    $jobError = $null
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    Set-WorkerMigration $WorkerId -Enable
    try {
        foreach ($key in $JobVariables.Keys) { Set-RailwayVariable $WorkerId $key $JobVariables[$key] }
        $migration = Publish-Service $WorkerId $Backend
        Confirm-DatabaseMigration $migration $WorkerId
        Write-Host "EF migration and nine Cognito bindings confirmed in worker deployment $migration."
    }
    catch { $jobError = $_ }
    finally {
        try {
            $emptyVariables = @($JobVariables.Keys | ForEach-Object { "$_=" })
            $null = Invoke-Railway (@('variable', 'set', '--project', $projectIdValue, '--environment', $environmentId, '--service', $WorkerId, '--skip-deploys') + $emptyVariables)
        } catch { $cleanupErrors.Add('temporary variable cleanup failed') }
        try { Set-WorkerMigration $WorkerId } catch { $cleanupErrors.Add('pre-deploy command cleanup failed') }
    }
    if ($cleanupErrors.Count -gt 0) {
        throw "Worker migration cleanup stopped: $($cleanupErrors -join ', '). Verify the existing private worker before publishing API or frontend."
    }
    $current = Get-Deployment $WorkerId
    if ($migration -or ($current -and $current.status -notin @('FAILED', 'CRASHED', 'REMOVED', 'SKIPPED', 'CANCELED') -and
            (-not $startingDeployment -or $current.id -ne $startingDeployment.id))) {
        $worker = Publish-Service $WorkerId $Backend
    }
    if ($jobError) { throw $jobError }
    return [pscustomobject] @{ MigrationDeployment = $migration; WorkerDeployment = $worker }
}

function Publish-ExistingVortexBird([hashtable] $Services) {
    foreach ($name in @('vortexbird-api', 'vortexbird-frontend', 'vortexbird-postgres', 'vortexbird-worker')) {
        if (-not $Services.ContainsKey($name)) { throw "Expected an existing Railway service named $name." }
        Assert-ServiceInEnvironment $Services[$name]
    }
    $apiId = $Services['vortexbird-api']
    $frontendId = $Services['vortexbird-frontend']
    $databaseId = $Services['vortexbird-postgres']
    $workerId = $Services['vortexbird-worker']
    Assert-PrivateService $databaseId 'vortexbird-postgres'
    Assert-PrivateService $workerId 'vortexbird-worker'
    Set-WorkerMigration $workerId -ValidateOnly
    $postgres = Get-Deployment $databaseId
    if (-not $postgres -or $postgres.status -ne 'SUCCESS') {
        throw 'The existing vortexbird-postgres deployment is not healthy in Railway.'
    }
    $databaseVariables = Invoke-RailwayJson @('variable', 'list', '--project', $projectIdValue, '--environment', $environmentId, '--service', $databaseId, '--json')
    $expected = @('PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE', 'DATABASE_URL')
    $missing = @($expected | Where-Object { -not $databaseVariables.PSObject.Properties[$_] })
    if ($missing.Count) { throw "vortexbird-postgres is missing variable names: $($missing -join ', ')." }
    if ($databaseVariables.PGHOST -notlike '*.railway.internal' -or $databaseVariables.PGPORT -notmatch '^\d{1,5}$') {
        throw 'The existing PostgreSQL service does not report a private Railway hostname and port.'
    }
    $privateHost = [string] $databaseVariables.PGHOST
    $privatePort = [int] $databaseVariables.PGPORT
    $databaseVariables = $null
    Write-Host ('PostgreSQL SUCCESS. Variable names present: ' + ($expected -join ', '))

    $backend = Join-Path $workspace 'vortexbird-backend'
    $frontend = Join-Path $workspace 'vortexbird-frontend'
    foreach ($source in @($backend, $frontend)) {
        if (-not (Test-Path -LiteralPath (Join-Path $source 'Dockerfile') -PathType Leaf)) {
            throw "Missing Dockerfile in the existing repository: $source"
        }
    }
    Assert-NoSourceDatabase
    $cognitoScript = Join-Path $PSScriptRoot 'Set-VortexBirdRailwayCognito.ps1'
    $identity = & $cognitoScript -Profile $AwsProfile -IncludeBindingManifest
    $frontendOrigin = Get-ServiceDomain $frontendId
    $database = & (Join-Path $PSScriptRoot 'New-VortexBirdRailwayDatabase.ps1') -ProjectId $projectIdValue -EnvironmentId $environmentId -DatabaseServiceId $databaseId -RailwayCli $RailwayCli
    if ($database.PrivateHost -ine $privateHost -or $database.PrivatePort -ne $privatePort) {
        throw 'Railway PostgreSQL variables do not match the verified private TLS origin.'
    }

    Set-Healthcheck $apiId '/health/ready'
    Set-Healthcheck $workerId '/health/ready' -AlwaysOn
    Set-Healthcheck $frontendId '/health'
    foreach ($serviceId in @($apiId, $workerId)) {
        Set-RailwayVariable $serviceId 'ASPNETCORE_ENVIRONMENT' 'Production'
        Set-RailwayVariable $serviceId 'PORT' '8080'
        Set-RailwayVariable $serviceId 'Authentication__Provider' 'Cognito'
        Set-RailwayVariable $serviceId 'Authentication__Authority' $identity.Issuer
        Set-RailwayVariable $serviceId 'Authentication__Cognito__ClientId' $identity.ClientId
        Set-RailwayVariable $serviceId 'Authentication__Cognito__AuthorizationOrigin' $identity.AuthorizationOrigin
        Set-RailwayVariable $serviceId 'Messaging__Provider' 'local'
        Set-RailwayVariable $serviceId 'Database__RootCertificatePem' $database.RootCertificatePem
    }
    Set-RailwayVariable $apiId 'Database__RailwayUrl' (New-DatabaseReference $database.ApiUrl)
    Set-RailwayVariable $workerId 'Database__RailwayUrl' (New-DatabaseReference $database.WorkerUrl)
    Set-RailwayVariable $apiId 'Workers__Enabled' 'false'
    Set-RailwayVariable $workerId 'Workers__Enabled' 'true'
    if ($frontendOrigin) { Set-RailwayVariable $apiId 'Cors__AllowedOrigins__0' $frontendOrigin }

    $jobVariables = [ordered] @{
        Deployment__RailwayUrl = (New-DatabaseReference $database.MigratorUrl)
        Database__RuntimeRoles__0 = 'vortexbird_api'
        Database__RuntimeRoles__1 = 'vortexbird_worker'
        Bootstrap__CognitoPilotManifest = ($identity.BindingManifest | ConvertTo-Json -Depth 8 -Compress)
    }
    $migration = Invoke-PrivateWorkerMigration $workerId $backend $jobVariables
    $apiDeployment = Publish-Service $apiId $backend
    $apiOrigin = Get-ServiceDomain $apiId -Create

    Set-RailwayVariable $frontendId 'PORT' '8080'
    Set-RailwayVariable $frontendId 'VITE_OIDC_PROVIDER' 'cognito'
    Set-RailwayVariable $frontendId 'VITE_COGNITO_ISSUER' $identity.Issuer
    Set-RailwayVariable $frontendId 'VITE_COGNITO_CLIENT_ID' $identity.ClientId
    Set-RailwayVariable $frontendId 'VITE_COGNITO_AUTHORIZATION_ORIGIN' $identity.AuthorizationOrigin
    Set-RailwayVariable $frontendId 'VITE_API_BASE_URL' "$apiOrigin/api/v1"
    Set-RailwayVariable $frontendId 'API_PROXY_ENABLED' 'false'
    $frontendDeployment = Publish-Service $frontendId $frontend
    $deployedFrontendOrigin = Get-ServiceDomain $frontendId -Create
    if ($frontendOrigin -ne $deployedFrontendOrigin) {
        Set-RailwayVariable $apiId 'Cors__AllowedOrigins__0' $deployedFrontendOrigin
        $apiDeployment = Publish-Service $apiId $backend
    }
    $ready = Invoke-WebRequest -Uri "$apiOrigin/health/ready" -Headers @{ Origin = $deployedFrontendOrigin } -UseBasicParsing -TimeoutSec 20
    $web = Invoke-WebRequest -Uri "$deployedFrontendOrigin/health" -UseBasicParsing -TimeoutSec 20
    if ($ready.StatusCode -ne 200 -or $web.StatusCode -ne 200 -or $ready.Headers['Access-Control-Allow-Origin'] -ne $deployedFrontendOrigin) {
        throw 'Railway HTTPS health checks or the frontend CORS check failed.'
    }
    $auth = Invoke-RestMethod -Uri "$apiOrigin/api/v1/auth/config" -TimeoutSec 20
    if ($auth.provider -ne 'cognito' -or $auth.authority -ne $identity.Issuer -or $auth.clientId -ne $identity.ClientId -or $auth.demoEnabled -ne $false) {
        throw 'The live API does not report the expected production Cognito configuration.'
    }
    $cognito = & $cognitoScript -Profile $AwsProfile -FrontendUrl $deployedFrontendOrigin -Apply -RailwayProjectId $projectIdValue -RailwayEnvironment $environmentId -RailwayCli $RailwayCli
    [pscustomobject] @{
        State = 'HEALTHY_PENDING_AUTHENTICATED_SMOKE_TEST'
        ApiOrigin = $apiOrigin
        FrontendOrigin = $deployedFrontendOrigin
        ApiDeployment = $apiDeployment
        FrontendDeployment = $frontendDeployment
        PostgresDeployment = $postgres.id
        WorkerDeployment = $migration.WorkerDeployment
        MigrationDeployment = $migration.MigrationDeployment
        ApiReadiness = $ready.StatusCode
        FrontendHealth = $web.StatusCode
        CognitoBindings = $cognito.BindingCount
    } | ConvertTo-Json -Depth 4
}

$version = (Invoke-Railway @('--version')) -join ' '
Write-Host $version
$target = Get-RailwayTarget

$projectIdValue = if ($target.ProjectId) { $target.ProjectId.ToString() } else { $null }

if ($Phase -eq 'Inspect') {
    if (-not $projectIdValue) {
        [pscustomobject] @{ Authenticated = $true; RailwayVersion = $version; Project = 'VortexBird'; WorkspaceId = $target.WorkspaceId; WorkspaceName = $target.WorkspaceName; State = 'NOT_FOUND' }
        return
    }
    $project = Get-Project $projectIdValue
    [pscustomobject] @{ Authenticated = $true; RailwayVersion = $version; Project = $project.name; ProjectId = $project.id; WorkspaceId = $target.WorkspaceId; WorkspaceName = $target.WorkspaceName; Services = (Get-Services $project) }
    return
}

if ($Phase -eq 'Deploy') {
    if (-not $projectIdValue -or $ProjectId -eq [guid]::Empty -or $WorkspaceId -eq [guid]::Empty -or $ExpectedEnvironmentId -eq [guid]::Empty) {
        throw 'Deploy requires -ProjectId, -WorkspaceId and -ExpectedEnvironmentId for the already provisioned VortexBird project.'
    }
    $project = Get-Project $projectIdValue
    $production = @($project.environments.edges | ForEach-Object { $_.node } | Where-Object Name -ceq 'production')
    if ($production.Count -ne 1 -or $production[0].id -ne $ExpectedEnvironmentId.ToString()) {
        throw 'The existing production environment does not match -ExpectedEnvironmentId.'
    }
    $environmentId = $ExpectedEnvironmentId.ToString()
    Publish-ExistingVortexBird (Get-Services $project)
    return
}

# Provision alone creates or links infrastructure.
$linkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('vortexbird-railway-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $linkDirectory
Push-Location -LiteralPath $linkDirectory
try {
    if (-not $projectIdValue) {
        $created = Invoke-RailwayJson @('init', '--name', 'VortexBird', '--workspace', $target.WorkspaceId.ToString(), '--json')
        if (-not $created.PSObject.Properties['id'] -or -not $created.PSObject.Properties['name'] -or $created.name -cne 'VortexBird') {
            throw 'railway init --json did not identify the created VortexBird project. Inspect railway list --json before retrying.'
        }
        $projectIdValue = (Read-RailwayId $created.id 'project ID from railway init --json').ToString()
    }

    $project = Get-Project $projectIdValue
    $production = @($project.environments.edges | ForEach-Object { $_.node } | Where-Object Name -CEQ 'production')
    if ($production.Count -ne 1) { throw 'VortexBird must have exactly one production environment.' }
    $environmentId = [string] $production[0].id
    $null = Invoke-Railway @('link', '--project', $projectIdValue, '--environment', $environmentId, '--json')
    $services = Get-Services $project

    if (-not $services.ContainsKey('vortexbird-postgres')) {
        if ($services.Keys -match '^postgres(?:ql)?(?:-|$)') {
            throw 'An existing default PostgreSQL service was detected in VortexBird. Verify it and rename it to vortexbird-postgres before retrying.'
        }
        $created = ((Invoke-Railway @('add', '--database', 'postgres', '--json')) -join "`n") | ConvertFrom-Json
        $createdId = ([guid] $created.serviceId).ToString()
        $added = Get-Services (Get-Project $projectIdValue)
        $newIds = @($added.Values | Where-Object { $services.Values -notcontains $_ })
        if ($newIds.Count -ne 1 -or $newIds[0] -ne $createdId -or $added[$created.serviceName] -ne $createdId -or $created.serviceName -notmatch '^postgres(?:ql)?(?:-|$)') {
            throw 'The PostgreSQL service could not be attributed to this run.'
        }
        $rename = 'mutation ($id: String!, $name: String!) { serviceUpdate(id: $id, input: { name: $name }) { id name } }'
        $null = Invoke-RailwayApi $rename @('--raw-var', "id=$createdId", '--raw-var', 'name=vortexbird-postgres')
        $services = Get-Services (Get-Project $projectIdValue)
    }
    Assert-ServiceInEnvironment $services['vortexbird-postgres']
    Assert-PrivateService $services['vortexbird-postgres'] 'vortexbird-postgres'

    foreach ($name in @('vortexbird-api', 'vortexbird-frontend', 'vortexbird-worker')) {
        if (-not $services.ContainsKey($name)) { $null = Invoke-Railway @('add', '--service', $name, '--json') }
    }
    $services = Get-Services (Get-Project $projectIdValue)
    $apiId = $services['vortexbird-api']
    $frontendId = $services['vortexbird-frontend']
    foreach ($serviceId in @($apiId, $frontendId, $services['vortexbird-worker'])) {
        Assert-ServiceInEnvironment $serviceId
        $null = Invoke-Railway @('variable', 'set', '--service', $serviceId, '--environment', $environmentId, '--project', $projectIdValue, '--skip-deploys', 'PORT=8080')
    }
    Set-Healthcheck $apiId '/health/ready'
    Set-Healthcheck $frontendId '/health'
    Set-Healthcheck $services['vortexbird-worker'] '/health/ready'

    $apiOrigin = Get-ServiceDomain $apiId -Create
    $frontendOrigin = Get-ServiceDomain $frontendId -Create
    $provisioning = [ordered] @{
        Project = $project.name
        ProjectId = $projectIdValue
        WorkspaceId = $target.WorkspaceId
        WorkspaceName = $target.WorkspaceName
        EnvironmentId = $environmentId
        Services = $services
        FrontendOrigin = $frontendOrigin
        ApiOrigin = $apiOrigin
        State = 'SERVICES_PROVISIONED_IMAGE_NOT_DEPLOYED'
    }
    [pscustomobject] $provisioning | ConvertTo-Json -Depth 4
}
finally {
    Pop-Location
}
