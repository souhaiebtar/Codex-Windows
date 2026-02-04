param(
  [string]$Configuration = "Release",
  [ValidateSet("win-x64","win-arm64")][string]$Runtime = "win-x64",
  [string]$OutDir = (Join-Path $PSScriptRoot "out"),
  [string]$WorkRoot = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# 1) Build the MSI (per-user) first.
& (Join-Path $PSScriptRoot "build-installer.ps1") `
  -Configuration $Configuration `
  -Runtime $Runtime `
  -OutDir $OutDir `
  -WorkRoot $WorkRoot `
  -CodexCliExe $CodexCliExe

$msiPath = Join-Path $OutDir "codexd.msi"
if (-not (Test-Path -Path $msiPath -PathType Leaf)) {
  throw "MSI not found: $msiPath"
}

# 2) Ensure WiX tool exists (reusing the one build-installer.ps1 placed in out\.tools).
$wix = Join-Path $OutDir ".tools\\wix.exe"
if (-not (Test-Path -Path $wix -PathType Leaf)) {
  throw "wix.exe not found: $wix"
}

# 3) Ensure Burn BA extension is available (per-user/global cache).
& $wix extension add -g WixToolset.BootstrapperApplications.wixext/6.0.2 | Out-Null

# 4) Build the setup.exe bundle.
$setupOut = Join-Path $OutDir "codexd-setup.exe"
Remove-Item -Force -ErrorAction SilentlyContinue $setupOut

$wixArch = if ($Runtime -eq "win-arm64") { "arm64" } else { "x64" }
$bundleLicense = (Resolve-Path (Join-Path $PSScriptRoot "license.rtf")).Path
$bundleIcon = (Resolve-Path (Join-Path $PSScriptRoot "..\\codexd-launcher\\codex.ico")).Path
$bundleLogo = (Resolve-Path (Join-Path $PSScriptRoot "..\\codex.png")).Path
& $wix build `
  (Join-Path $PSScriptRoot "CodexdBundle.wxs") `
  -arch $wixArch `
  -ext WixToolset.BootstrapperApplications.wixext `
  -d "MsiPath=$msiPath" `
  -d "BundleLicense=$bundleLicense" `
  -d "BundleIcon=$bundleIcon" `
  -d "BundleLogo=$bundleLogo" `
  -out $setupOut
if ($LASTEXITCODE -ne 0) { throw "wix build bundle failed (exit $LASTEXITCODE)" }
if (-not (Test-Path -Path $setupOut -PathType Leaf)) { throw "Expected output not found: $setupOut" }

Write-Host "Wrote: $setupOut" -ForegroundColor Green
