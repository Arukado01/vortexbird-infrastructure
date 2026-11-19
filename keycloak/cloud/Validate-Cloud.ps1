[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$checks = [Collections.Generic.List[object]]::new()
function Assert-Cloud([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "Cloud identity contract failed: $Name" }
    $checks.Add([pscustomobject]@{ name=$Name; status='passed'; type='static' })
}
$raw = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'realm-template.json') -Raw -Encoding utf8
$realm = $raw | ConvertFrom-Json
$portal = @($realm.clients | Where-Object clientId -eq 'vortexbird-portal')[0]
$placeholder = '${VORTEXBIRD_PORTAL_ORIGIN}'
Assert-Cloud 'Production realm, HTTPS required, self-registration closed' ($realm.realm -eq 'vortexbird' -and $realm.enabled -and $realm.sslRequired -eq 'all' -and -not $realm.registrationAllowed)
Assert-Cloud 'Realm contains no users, credentials, client secrets or SMTP secrets' ($raw -notmatch '"(users|credentials|secret|clientSecret|smtpServer|password)"\s*:')
Assert-Cloud 'Public authorization-code client, no password/implicit/service grants' ($portal.publicClient -and $portal.standardFlowEnabled -and -not $portal.directAccessGrantsEnabled -and -not $portal.implicitFlowEnabled -and -not $portal.serviceAccountsEnabled)
Assert-Cloud 'S256 is mandatory' ($portal.attributes.'pkce.code.challenge.method' -eq 'S256')
Assert-Cloud 'Redirects are exactly the portal origin and root path' ((@($portal.redirectUris) -join '|') -eq "$placeholder|$placeholder/")
Assert-Cloud 'Web origin is exact and logout redirects to the exact origin' ((@($portal.webOrigins) -join '|') -eq $placeholder -and $portal.attributes.'post.logout.redirect.uris' -eq $placeholder)
$variables = @([regex]::Matches($raw, '\$\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert-Cloud 'Only the reviewed public origin environment placeholder is imported' ($variables.Count -eq 1 -and $variables[0] -eq 'VORTEXBIRD_PORTAL_ORIGIN')
$audience = $portal.protocolMappers | Where-Object { $_.protocolMapper -eq 'oidc-audience-mapper' -and $_.config.'included.custom.audience' -eq 'vortexbird-api' }
$identity = $portal.protocolMappers | Where-Object { $_.config.'claim.name' -eq 'identity_type' -and $_.config.'claim.value' -eq 'human' }
Assert-Cloud 'Access tokens have API audience and human identity claim' ([bool]$audience -and [bool]$identity)
$profile = $realm.components.'org.keycloak.userprofile.UserProfileProvider'[0].config.'kc.user.profile.config'[0] | ConvertFrom-Json
$scoped = @($profile.attributes | Where-Object { $_.name -in @('partner_id','channel_id') })
Assert-Cloud 'Partner and channel claims are admin managed; unmanaged attributes disabled' ($profile.unmanagedAttributePolicy -eq 'DISABLED' -and $scoped.Count -eq 2 -and @($scoped | Where-Object { (@($_.permissions.edit) -join '|') -ne 'admin' }).Count -eq 0)
Assert-Cloud 'Refresh rotation, email verification and brute-force protection enabled' ($realm.verifyEmail -and $realm.bruteForceProtected -and $realm.revokeRefreshToken -and $realm.refreshTokenMaxReuse -eq 0)

$docker = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Dockerfile') -Raw
$entrypoint = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'entrypoint.sh') -Raw
$runtime = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'validate-runtime.sh') -Raw
$health = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'healthcheck.sh') -Raw
$build = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Build-Image.ps1') -Raw
Assert-Cloud 'Optimized build includes PostgreSQL and health/metrics at build time' ($docker -match 'RUN /opt/keycloak/bin/kc.sh build' -and $docker -match 'KC_DB=postgres' -and $docker -match 'KC_HEALTH_ENABLED=true' -and $docker -match 'KC_METRICS_ENABLED=true')
Assert-Cloud 'Reviewed official image digest is mandatory; no mutable default' ($docker -match '(?m)^ARG KEYCLOAK_IMAGE$' -and $docker -notmatch ':latest|ARG KEYCLOAK_IMAGE=' -and $build -match '26\\\.8\\\.2@sha256:')
Assert-Cloud 'No secret build arguments/defaults and final UID is non-root' ($docker -notmatch '(?im)^(ARG|ENV)\s+\w*(PASSWORD|SECRET|TOKEN|USERNAME)\w*\s*=' -and $docker -match '(?m)^USER 1000$')
Assert-Cloud 'Production command includes import; development commands cannot start' ($docker -match 'CMD \["start", "--optimized", "--import-realm"\]' -and $entrypoint -match '\$1" != start' -and $entrypoint -match '\$3" != --import-realm')
Assert-Cloud 'Management health is on 9000 and JDBC discovery is enabled' ($health -match '/dev/tcp/127.0.0.1/9000' -and $health -match '/health/ready' -and $docker -match 'KC_CACHE_STACK=jdbc-ping' -and $docker -match 'KC_HTTP_MANAGEMENT_PORT=9000')
Assert-Cloud 'Runtime accepts a dedicated HTTPS origin or the exact portal /auth URL with trusted proxies and DB TLS' ($runtime -match 'https_origin VORTEXBIRD_PORTAL_ORIGIN' -and $runtime -match 'https_origin KC_HOSTNAME' -and $runtime.Contains('"$VORTEXBIRD_PORTAL_ORIGIN/auth"') -and $runtime -match 'KC_PROXY_TRUSTED_ADDRESSES' -and $runtime -match 'sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca-bundle.pem')
Assert-Cloud 'Public CA bundle is checked by reviewed hash and certificate constraints before build' ($build -match 'Get-FileHash.*SHA256' -and $build -match 'PRIVATE KEY' -and $build -match 'CertificateAuthority' -and $build -match 'NotAfter' -and $docker -match '/opt/keycloak/conf/rds-ca-bundle.pem')
$parseErrors = @()
foreach ($file in @('Build-Image.ps1','Validate-Cloud.ps1')) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$errors)
    $parseErrors += $errors
}
Assert-Cloud 'PowerShell build and validation scripts parse without errors' ($parseErrors.Count -eq 0)
foreach ($file in @('entrypoint.sh','validate-runtime.sh','healthcheck.sh')) {
    Assert-Cloud "$file has LF endings and a Bash shebang" ((Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw) -notmatch "`r" -and (Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -TotalCount 1) -eq '#!/bin/bash')
}
$sourceFiles = @('Dockerfile','realm-template.json','entrypoint.sh','validate-runtime.sh','healthcheck.sh','Build-Image.ps1','Validate-Cloud.ps1')
$result = [ordered]@{
    recordedAt=(Get-Date).ToString('o'); scope='Cloud Keycloak image source preparation'; status='static_checks_passed_runtime_not_executed'
    checks=$checks; passed=$checks.Count; failed=0; dockerBuildExecuted=$false; imagePublished=$false; realmImported=$false; cloudResourcesChanged=$false
    files=@($sourceFiles | ForEach-Object { [ordered]@{name=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant()} })
    limitations=@('Static contracts do not prove a successful container build, Keycloak import, TLS connection, JDBC_PING cluster or running service.','A real reviewed official-image digest and public RDS CA bundle/hash are required before build.','No image download, Docker build, ECR push or AWS mutation was executed by this validator.')
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'static-validation.json') -Encoding utf8
Write-Output "PASS $($checks.Count) cloud identity source checks; runtime and Docker build were not executed."
