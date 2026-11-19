#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$Profile = 'btc-deploy', [switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$region = 'us-east-2'
$poolId = 'us-east-2_nLop817zD'
$clientId = '3leshk5524vr3rrc82g1trijub'
$root = Split-Path -Parent $PSScriptRoot
$workDir = Join-Path (Join-Path $root '.work') 'branding'
$awsOptions = @('--profile', $Profile, '--region', $region, '--output', 'json', '--no-cli-pager')

function Invoke-Aws {
    param([string[]]$Arguments, [string]$Resource)
    $output = & aws @Arguments @awsOptions 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join ' '
        throw "AWS $($Arguments[0]) failed for ${Resource}: $detail"
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

# Base: the merged defaults for this client, so the settings document always matches the schema.
$existing = Invoke-Aws -Arguments @('cognito-idp', 'describe-managed-login-branding-by-client', '--user-pool-id', $poolId,
    '--client-id', $clientId, '--return-merged-resources') -Resource 'branding settings'
$settings = $existing.ManagedLoginBranding.Settings

# VortexBird palette (see src/styles/index.css tokens). Permanent DARK: the access experience is a
# brand moment that always matches the dark portal login, regardless of the browser preference.
$settings.categories.global.colorSchemeMode = 'DARK'
$form = $settings.components.form
$form.borderRadius = 14
$form.lightMode.backgroundColor = 'ffffffff'; $form.lightMode.borderColor = 'e8edf2ff'
$form.darkMode.backgroundColor = '122032ff';  $form.darkMode.borderColor = '26364aff'
$form.logo.enabled = $true; $form.logo.location = 'CENTER'; $form.logo.position = 'TOP'; $form.logo.formInclusion = 'IN'
$background = $settings.components.pageBackground
$background.image.enabled = $false
$background.lightMode.color = 'f5f7faff'
$background.darkMode.color = '0c1724ff'
$text = $settings.components.pageText
$text.lightMode.headingColor = '15263bff'; $text.lightMode.bodyColor = '5d6b7cff'; $text.lightMode.descriptionColor = '5d6b7cff'
$text.darkMode.headingColor = 'e5edf6ff';  $text.darkMode.bodyColor = '93a4b8ff'; $text.darkMode.descriptionColor = '93a4b8ff'
$primary = $settings.components.primaryButton
$primary.lightMode.defaults.backgroundColor = '0aa39bff'; $primary.lightMode.defaults.textColor = 'ffffffff'
$primary.lightMode.hover.backgroundColor = '087e7aff';    $primary.lightMode.hover.textColor = 'ffffffff'
$primary.lightMode.active.backgroundColor = '056b67ff';   $primary.lightMode.active.textColor = 'ffffffff'
$primary.lightMode.disabled = [pscustomobject]@{ backgroundColor = 'e8edf2ff'; borderColor = 'e8edf2ff' }
$primary.darkMode.defaults.backgroundColor = '12bfb2ff';  $primary.darkMode.defaults.textColor = '04141fff'
$primary.darkMode.hover.backgroundColor = '2fd0c0ff';     $primary.darkMode.hover.textColor = '04141fff'
$primary.darkMode.active.backgroundColor = '0aa39bff';    $primary.darkMode.active.textColor = 'ffffffff'
$primary.darkMode.disabled = [pscustomobject]@{ backgroundColor = '26364aff'; borderColor = '26364aff' }
$secondary = $settings.components.secondaryButton
$secondary.lightMode.defaults = [pscustomobject]@{ backgroundColor = 'ffffffff'; borderColor = 'e8edf2ff'; textColor = '15263bff' }
$secondary.lightMode.hover = [pscustomobject]@{ backgroundColor = 'fafbfdff'; borderColor = '0aa39bff'; textColor = '079e98ff' }
$secondary.lightMode.active = [pscustomobject]@{ backgroundColor = 'e8f8f6ff'; borderColor = '0aa39bff'; textColor = '079e98ff' }
$secondary.darkMode.defaults = [pscustomobject]@{ backgroundColor = '162539ff'; borderColor = '26364aff'; textColor = 'e5edf6ff' }
$secondary.darkMode.hover = [pscustomobject]@{ backgroundColor = '1d3044ff'; borderColor = '2fd0c0ff'; textColor = '2fd0c0ff' }
$secondary.darkMode.active = [pscustomobject]@{ backgroundColor = '26364aff'; borderColor = '2fd0c0ff'; textColor = '2fd0c0ff' }
$alert = $settings.components.alert
$alert.lightMode.error = [pscustomobject]@{ backgroundColor = 'fff0f1ff'; borderColor = 'e08494ff' }
$alert.darkMode.error = [pscustomobject]@{ backgroundColor = '2a1218ff'; borderColor = 'e08494ff' }

$settingsPath = Join-Path $workDir 'settings-final.json'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$settings | ConvertTo-Json -Depth 24 | Set-Content -Encoding utf8 $settingsPath

# Assets: brand favicon plus the VortexBird lockup for the form card (light and dark variants).
function Add-Asset([string]$Path, [string]$Category, [string]$ColorMode, [string]$Extension) {
    [pscustomobject]@{ Category = $Category; ColorMode = $ColorMode; Extension = $Extension; Bytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
}
$assets = @(
    (Add-Asset (Join-Path $workDir 'favicon.svg') 'FAVICON_SVG' 'LIGHT' 'SVG'),
    (Add-Asset (Join-Path $workDir 'logo-light.svg') 'FORM_LOGO' 'LIGHT' 'SVG'),
    (Add-Asset (Join-Path $workDir 'logo-dark.svg') 'FORM_LOGO' 'DARK' 'SVG')
)
$assetsPath = Join-Path $workDir 'assets.json'
ConvertTo-Json -InputObject $assets -Depth 4 | Set-Content -Encoding utf8 $assetsPath

Write-Host "Settings: $settingsPath ($((Get-Item $settingsPath).Length) bytes); assets: $assetsPath"
if (-not $Apply) { Write-Host 'Dry run complete (use -Apply to create the style).'; return }

$assigned = $null
try {
    $assigned = Invoke-Aws -Arguments @('cognito-idp', 'describe-managed-login-branding-by-client', '--user-pool-id', $poolId,
        '--client-id', $clientId) -Resource 'client style'
} catch { }
$assignedId = if ($assigned -and $assigned.ManagedLoginBranding.PSObject.Properties['ManagedLoginBrandingId']) { $assigned.ManagedLoginBranding.ManagedLoginBrandingId } else { $null }
$assignedClient = if ($assigned -and $assigned.ManagedLoginBranding.PSObject.Properties['ClientId']) { $assigned.ManagedLoginBranding.ClientId } else { $null }
if ($assignedId -and $assignedClient -eq $clientId) {
    throw "The client already owns style $assignedId; delete it before applying a new one."
}
$result = Invoke-Aws -Arguments @('cognito-idp', 'create-managed-login-branding', '--user-pool-id', $poolId, '--client-id', $clientId,
    '--no-use-cognito-provided-values', '--settings', "file://$settingsPath", '--assets', "file://$assetsPath") -Resource 'create branding'
Write-Host "Branding style created: $($result.ManagedLoginBranding.ManagedLoginBrandingId)"
