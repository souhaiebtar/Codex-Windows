param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\\work"),
  [switch]$Reuse,
  [bool]$NoLaunch = $true,
  [string]$CodexCliExe,
  [switch]$AllowMissingCodexCli,
  [string]$Configuration = "Release",
  [ValidateSet("win-x64","win-arm64")][string]$Runtime = "win-x64",
  [string]$OutDir = (Join-Path $PSScriptRoot "..\\installer\\out")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$runScript = Join-Path $repoRoot "scripts\\run.ps1"
$buildScript = Join-Path $repoRoot "installer\\build-installer-exe.ps1"

if (-not (Test-Path $runScript -PathType Leaf)) { throw "run.ps1 not found: $runScript" }
if (-not (Test-Path $buildScript -PathType Leaf)) { throw "build-installer-exe.ps1 not found: $buildScript" }

Write-Host "Running run.ps1..." -ForegroundColor Cyan
$runArgs = @{}
if ($DmgPath) { $runArgs.DmgPath = $DmgPath }
if ($WorkDir) { $runArgs.WorkDir = $WorkDir }
if ($Reuse) { $runArgs.Reuse = $true }
if ($NoLaunch) { $runArgs.NoLaunch = $true }
& $runScript @runArgs

Write-Host "Building CodexDesktop.exe + setup.exe..." -ForegroundColor Cyan
$buildArgs = @{
  Configuration = $Configuration
  Runtime = $Runtime
  OutDir = $OutDir
  WorkRoot = $WorkDir
}
if ($CodexCliExe) { $buildArgs.CodexCliExe = $CodexCliExe }
if ($AllowMissingCodexCli) { $buildArgs.AllowMissingCodexCli = $true }
if ($env:ALLOW_MISSING_CODEX_CLI -eq "1" -or $env:CODEX_ALLOW_MISSING_CLI -eq "1") {
  $buildArgs.AllowMissingCodexCli = $true
}
& $buildScript @buildArgs

Write-Host "Removing MSI artifacts..." -ForegroundColor Cyan
$msiArtifacts = @(
  (Join-Path $OutDir "codexd.msi"),
  (Join-Path $OutDir "codexd.wixpdb"),
  (Join-Path $OutDir "CodexDesktop.msi"),
  (Join-Path $OutDir "CodexDesktop.wixpdb"),
  (Join-Path $OutDir "WorkFiles.wxs")
)
$msiArtifacts += (Get-ChildItem -Path $OutDir -Filter "cab*.cab" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
foreach ($p in $msiArtifacts) { Remove-Item -Force -ErrorAction SilentlyContinue $p }

$setupExe = Join-Path $OutDir "CodexDesktop-setup.exe"
if (-not (Test-Path $setupExe -PathType Leaf)) {
  throw "Expected setup.exe not found: $setupExe"
}

Write-Host "Wrote: $setupExe" -ForegroundColor Green
