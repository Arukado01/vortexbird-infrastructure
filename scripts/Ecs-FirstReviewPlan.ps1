# Private helpers for the initial, speculative ECS foundation review.
function Copy-EcsFirstReviewSource([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path (Join-Path $Destination 'environments') -ErrorAction Stop | Out-Null
    $files = @(Get-ChildItem -LiteralPath $Source -File -Filter '*.tf' -ErrorAction Stop)
    $files += Get-Item -LiteralPath (Join-Path $Source '.terraform.lock.hcl')
    foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination $Destination -ErrorAction Stop }
    Copy-Item -LiteralPath (Join-Path $Source 'environments/development.tfvars') -Destination (Join-Path $Destination 'environments')
    $versions = Join-Path $Destination 'versions.tf'
    $body = [IO.File]::ReadAllText($versions)
    $backend = [regex]'(?m)^([ \t]*)backend "s3" \{\}([ \t]*)(?=\r?$)'
    if ($backend.Matches($body).Count -ne 1) { throw 'Unexpected S3 backend declaration in the ECS source.' }
    [IO.File]::WriteAllText($versions, $backend.Replace($body, '$1backend "local" {}$2'))
}

function Get-EcsFirstReviewChanges([string]$PlanStream) {
    $resources = @{}
    $addresses = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $summary = $null
    foreach ($line in ($PlanStream -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = ConvertFrom-Json -AsHashtable -InputObject $line -ErrorAction Stop }
        catch { throw 'Invalid machine-readable Terraform output.' }
        if ($event.type -eq 'diagnostic' -and $event.diagnostic.severity -eq 'error') { throw 'Terraform emitted an error diagnostic.' }
        if ($event.type -eq 'change_summary') {
            if ($null -ne $summary) { throw 'Multiple Terraform change summaries.' }
            $summary = $event.changes
        }
        if ($event.type -ne 'planned_change') { continue }
        $change = $event.change
        $resource = $change.resource
        if ($change.action -eq 'read' -and $resource.addr -cmatch '^data\.') { continue }
        if ($change.action -cne 'create' -or $resource.resource_type -cnotmatch '^aws_[a-z0-9_]+$' -or
            $resource.addr -cnotmatch ('^' + [regex]::Escape($resource.resource_type) + '\.') -or
            -not $addresses.Add($resource.addr)) { throw 'The plan contains an unexpected resource action or address.' }
        if ($resource.resource_type -in @('aws_ecs_service','aws_ecs_task_definition','aws_lb_listener','aws_lb_listener_rule','aws_lb_listener_certificate','aws_route53_record','aws_acm_certificate','aws_acm_certificate_validation','aws_elasticache_replication_group')) {
            throw 'The plan activates services, Redis, routing or TLS outside the foundation scope.'
        }
        $resources[$resource.resource_type] = 1 + [int]$resources[$resource.resource_type]
    }
    if ($null -eq $summary -or $summary.operation -ne 'plan' -or $addresses.Count -eq 0 -or
        $summary.add -ne $addresses.Count -or $summary.change -ne 0 -or $summary.remove -ne 0 -or
        ($summary.Contains('import') -and $summary.import -ne 0)) { throw 'Terraform action totals do not match the greenfield review.' }
    foreach ($required in @('aws_ecs_cluster.main','aws_vpc.main','aws_lb.edge','aws_db_instance.main','aws_db_instance.identity[0]')) {
        if (-not $addresses.Contains($required)) { throw 'The plan is missing a required foundation resource.' }
    }
    [ordered]@{
        create = $addresses.Count; update = 0; delete = 0
        resourcesByType = @(foreach ($type in ($resources.Keys | Sort-Object)) { [ordered]@{ type = $type; count = $resources[$type] } })
        identityDatabase = $true; plannedEcsServices = 0; plannedPublicListeners = 0
    }
}
