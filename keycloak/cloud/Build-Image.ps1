[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^quay\.io/keycloak/keycloak:26\.8\.2@sha256:[a-f0-9]{64}$')][string]$KeycloakImage,
    [Parameter(Mandatory)][string]$RdsCaBundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RdsCaBundleSha256,
    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*:[a-zA-Z0-9._-]+$')][string]$ImageTag = 'vortexbird-keycloak:26.8.2'
)
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Validate-Cloud.ps1')
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker is required to build the image.' }
$certificatePath = (Resolve-Path -LiteralPath $RdsCaBundlePath).Path
$actualHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash
if ($actualHash -ne $RdsCaBundleSha256) { throw 'The CA bundle does not match its independently reviewed SHA-256.' }
$pem = Get-Content -LiteralPath $certificatePath -Raw
if ($pem -match 'PRIVATE KEY') { throw 'Only a public RDS certificate bundle is permitted.' }
$certificates = [regex]::Matches($pem, '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
if ($certificates.Count -eq 0) { throw 'No PEM certificates were found.' }
foreach ($item in $certificates) {
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String(($item.Groups[1].Value -replace '\s', '')))
    try {
        if ($certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow) { throw 'The bundle contains a certificate outside its validity period.' }
        $constraints = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
        if (-not $constraints -or -not [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($constraints, $constraints.Critical).CertificateAuthority) {
            throw 'The bundle must contain CA certificates, not leaf certificates.'
        }
    } finally { $certificate.Dispose() }
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$context = Join-Path $temporaryRoot ('vortexbird-keycloak-build-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $context
try {
    foreach ($name in @('Dockerfile', '.dockerignore', 'realm-template.json', 'entrypoint.sh', 'validate-runtime.sh', 'healthcheck.sh')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $context $name)
    }
    Copy-Item -LiteralPath $certificatePath -Destination (Join-Path $context 'rds-ca-bundle.pem')
    & docker build --platform linux/amd64 --build-arg "KEYCLOAK_IMAGE=$KeycloakImage" --tag $ImageTag $context
    if ($LASTEXITCODE -ne 0) { throw 'The identity image build failed.' }
    Write-Output 'Identity image built locally. No ECR push, cloud resource or deployment was performed.'
} finally {
    $resolvedContext = (Resolve-Path -LiteralPath $context).Path
    $expectedPrefix = $temporaryRoot + [IO.Path]::DirectorySeparatorChar + 'vortexbird-keycloak-build-'
    if (-not $resolvedContext.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or $resolvedContext -ne $context) {
        throw 'Cleanup refused: temporary build context is outside its verified boundary.'
    }
    Remove-Item -LiteralPath $resolvedContext -Recurse -Force
}
