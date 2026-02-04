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

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$workRootAbs = (Resolve-Path $WorkRoot).Path

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$oldArtifacts = @(
  (Join-Path $OutDir "codexd.msi"),
  (Join-Path $OutDir "codexd.wixpdb"),
  (Join-Path $OutDir "CodexDesktop.msi"),
  (Join-Path $OutDir "CodexDesktop.wixpdb")
)
$oldArtifacts += (Get-ChildItem -Path $OutDir -Filter "cab*.cab" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
foreach ($p in $oldArtifacts) { Remove-Item -Force -ErrorAction SilentlyContinue $p }

Write-Host "Publishing CodexDesktop.exe..." -ForegroundColor Cyan
$publishDir = Join-Path $OutDir "publish"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $publishDir
dotnet publish (Join-Path $repoRoot "codexd-launcher\CodexdLauncher.csproj") -c $Configuration -r $Runtime -p:PublishSingleFile=true -p:SelfContained=true -p:PublishDir=$publishDir | Out-Null

$codexdExe = Join-Path $publishDir "CodexDesktop.exe"
if (-not (Test-Path -Path $codexdExe -PathType Leaf)) {
  throw "CodexDesktop.exe not found after publish: $codexdExe"
}

function Resolve-CodexCliExe([string]$Explicit) {
  if ($Explicit) {
    if (Test-Path -Path $Explicit -PathType Leaf) { return (Resolve-Path $Explicit).Path }
    throw "CodexCliExe not found: $Explicit"
  }
  if ($env:CODEX_CLI_PATH -and (Test-Path -Path $env:CODEX_CLI_PATH -PathType Leaf)) {
    return (Resolve-Path $env:CODEX_CLI_PATH).Path
  }
  try {
    $where = & where.exe codex.exe 2>$null
    foreach ($c in $where) {
      if ($c -and (Test-Path -Path $c -PathType Leaf)) { return (Resolve-Path $c).Path }
    }
  } catch {}
  $appData = [Environment]::GetFolderPath("ApplicationData")
  if ($appData) {
    $vend = Join-Path $appData "npm\node_modules\@openai\codex\vendor"
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
    $cands = @(
      (Join-Path $vend "$arch\codex\codex.exe"),
      (Join-Path $vend "x86_64-pc-windows-msvc\codex\codex.exe"),
      (Join-Path $vend "aarch64-pc-windows-msvc\codex\codex.exe")
    )
    foreach ($c in $cands) {
      if (Test-Path -Path $c -PathType Leaf) { return (Resolve-Path $c).Path }
    }
  }
  return $null
}

Write-Host "Resolving codex.exe (CLI)..." -ForegroundColor Cyan
$codexCliAbs = Resolve-CodexCliExe $CodexCliExe
if (-not $codexCliAbs) {
  throw "codex.exe not found. Pass -CodexCliExe <path>, set CODEX_CLI_PATH, or ensure codex.exe is discoverable in PATH (not the npm shim)."
}

Write-Host "Generating WiX payload list..." -ForegroundColor Cyan
$workFiles = Join-Path $OutDir "WorkFiles.wxs"
& (Join-Path $PSScriptRoot "generate-workfiles.ps1") -WorkRoot $workRootAbs -OutPath $workFiles

Write-Host "Installing WiX tool (local)..." -ForegroundColor Cyan
$toolsDir = Join-Path $OutDir ".tools"
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
$wix = Join-Path $toolsDir "wix.exe"
if (-not (Test-Path $wix)) {
  dotnet tool install --tool-path $toolsDir wix --version 6.0.2 | Out-Null
}
if (-not (Test-Path $wix)) { throw "wix.exe not found: $wix" }

Write-Host "Building MSI..." -ForegroundColor Cyan
$msiOut = Join-Path $OutDir "CodexDesktop.msi"
$wixArch = if ($Runtime -eq "win-arm64") { "arm64" } else { "x64" }
& $wix build `
  (Join-Path $PSScriptRoot "CodexdInstaller.wxs") `
  $workFiles `
  -arch $wixArch `
  -d "CodexdExe=$codexdExe" `
  -d "CodexCliExe=$codexCliAbs" `
  -d "WorkPayloadSource=$workRootAbs" `
  -out $msiOut | Out-Null

Write-Host "Wrote: $msiOut" -ForegroundColor Green
