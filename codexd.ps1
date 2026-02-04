param(
  [string]$CodexDesktopPath = "C:\Users\tunknown\projects\Codex-Windows\work",
  [string]$CodexCliPath,
  [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
}

function Resolve-CodexCliPath([string]$Explicit) {
  if ($Explicit) {
    if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride -and (Test-Path $envOverride)) {
    return (Resolve-Path $envOverride).Path
  }

  $candidates = @()

  try {
    $whereExe = & where.exe codex.exe 2>$null
    if ($whereExe) { $candidates += $whereExe }
    $whereCmd = & where.exe codex 2>$null
    if ($whereCmd) { $candidates += $whereCmd }
  } catch {}

  try {
    $npmRoot = (& npm root -g 2>$null).Trim()
    if ($npmRoot) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\$arch\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($c in $candidates) {
    if (-not $c) { continue }
    if ($c -match '\.cmd$' -and (Test-Path $c)) {
      try {
        $cmdDir = Split-Path $c -Parent
        $vendor = Join-Path $cmdDir "node_modules\@openai\codex\vendor"
        if (Test-Path $vendor) {
          $found = Get-ChildItem -Recurse -Filter "codex.exe" $vendor -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($found) { return (Resolve-Path $found.FullName).Path }
        }
      } catch {}
    }
    if (Test-Path $c) {
      return (Resolve-Path $c).Path
    }
  }

  return $null
}

function Write-Header([string]$Text) {
  Write-Verbose "=== $Text ==="
}

function Patch-Preload([string]$AppDir) {
  $preload = Join-Path $AppDir ".vite\build\preload.js"
  if (-not (Test-Path $preload)) { return }
  $raw = Get-Content -Raw $preload
  $processExpose = 'const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld("process",P);'
  if ($raw -notlike "*$processExpose*") {
    $re = 'n\.contextBridge\.exposeInMainWorld\("codexWindowType",[A-Za-z0-9_$]+\);n\.contextBridge\.exposeInMainWorld\("electronBridge",[A-Za-z0-9_$]+\);'
    $m = [regex]::Match($raw, $re)
    if (-not $m.Success) { throw "preload patch point not found." }
    $raw = $raw.Replace($m.Value, "$processExpose$m")
    Set-Content -NoNewline -Path $preload -Value $raw
  }
}

function Ensure-GitOnPath() {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\bin\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin\git.exe")
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates -or $candidates.Count -eq 0) { return }
  $gitDir = Split-Path $candidates[0] -Parent
  if ($env:PATH -notlike "*$gitDir*") {
    $env:PATH = "$gitDir;$env:PATH"
  }
}

Ensure-Command node
Ensure-Command npm
Ensure-Command npx

foreach ($k in @("npm_config_runtime", "npm_config_target", "npm_config_disturl", "npm_config_arch", "npm_config_build_from_source")) {
  if (Test-Path "Env:$k") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

if (-not (Test-Path -Path $CodexDesktopPath -PathType Container)) {
  throw "CodexDesktopPath not found: $CodexDesktopPath. Change -CodexDesktopPath or create the directory."
}

$WorkDir = (Resolve-Path $CodexDesktopPath).Path
$appDir = Join-Path $WorkDir "app"
$nativeDir = Join-Path $WorkDir "native-builds"
$userDataDir = Join-Path $WorkDir "userdata"
$cacheDir = Join-Path $WorkDir "cache"

$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path -Path $pkgPath -PathType Leaf)) {
  throw "No extracted app found in: $WorkDir. Expected: $pkgPath. Create/populate $appDir first (this script assumes the app is already extracted)."
}

Write-Header "Patching preload"
Patch-Preload $appDir

Write-Header "Reading app metadata"
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
$electronVersion = $pkg.devDependencies.electron
$betterVersion = $pkg.dependencies."better-sqlite3"
$ptyVersion = $pkg.dependencies."node-pty"

if (-not $electronVersion) { throw "Electron version not found." }

Write-Header "Preparing native modules"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$bsDst = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"
$skipNative = (Test-Path $bsDst) -and (Test-Path (Join-Path $ptyDstPre "pty.node"))
if ($skipNative) {
  Write-Verbose "Native modules already present in app. Skipping rebuild."
} else {
  New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
  Push-Location $nativeDir
  if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
    & npm init -y 1>$null
  }

  $bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $ptySrcProbe = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch\pty.node"
  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
  $haveNative = (Test-Path $bsSrcProbe) -and (Test-Path $ptySrcProbe) -and (Test-Path $electronExe)

  if (-not $haveNative) {
    $deps = @(
      "better-sqlite3@$betterVersion",
      "node-pty@$ptyVersion",
      "@electron/rebuild",
      "prebuild-install",
      "electron@$electronVersion"
    )
    & npm install --no-save @deps 1>$null
    if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
    $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
  } else {
    Write-Verbose "Native modules already present. Skipping rebuild."
  }

  Write-Verbose "Rebuilding native modules for Electron $electronVersion..."
  $rebuildOk = $true
  if (-not $haveNative) {
    try {
      $rebuildCli = Join-Path $nativeDir "node_modules\@electron\rebuild\lib\cli.js"
      if (-not (Test-Path $rebuildCli)) { throw "electron-rebuild not found." }
      & node $rebuildCli -v $electronVersion -w "better-sqlite3,node-pty" 1>$null
    } catch {
      $rebuildOk = $false
      Write-Warning "electron-rebuild failed: $($_.Exception.Message)"
    }
  }

  if (-not $rebuildOk -and -not $haveNative) {
    Write-Warning "Trying prebuilt Electron binaries for better-sqlite3..."
    $bsDir = Join-Path $nativeDir "node_modules\better-sqlite3"
    if (Test-Path $bsDir) {
      Push-Location $bsDir
      $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
      if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
      & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v 1>$null
      Pop-Location
    }
  }

  $env:ELECTRON_RUN_AS_NODE = "1"
  if (-not (Test-Path $electronExe)) { throw "electron.exe not found." }
  if (-not (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3"))) {
    throw "better-sqlite3 not installed."
  }
  & $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" 1>$null
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  if ($LASTEXITCODE -ne 0) { throw "better-sqlite3 failed to load." }

  Pop-Location

  $bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $bsDstDir = Split-Path $bsDst -Parent
  New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
  if (-not (Test-Path $bsSrc)) { throw "better_sqlite3.node not found." }
  Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")

  $ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
  $ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
  New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
  New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null

  $ptyFiles = @("pty.node", "conpty.node", "conpty_console_list.node")
  foreach ($f in $ptyFiles) {
    $src = Join-Path $ptySrcDir $f
    if (Test-Path $src) {
      Copy-Item -Force $src (Join-Path $ptyDstPre $f)
      Copy-Item -Force $src (Join-Path $ptyDstRel $f)
    }
  }
}

if (-not $NoLaunch) {
  Write-Header "Resolving Codex CLI"
  $cli = Resolve-CodexCliPath $CodexCliPath
  if (-not $cli) { throw "codex.exe not found (set -CodexCliPath or CODEX_CLI_PATH)." }

  Write-Header "Launching Codex"
  $rendererUrl = (New-Object System.Uri (Join-Path $appDir "webview\index.html")).AbsoluteUri
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_RENDERER_URL = $rendererUrl
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $buildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $buildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $cli
  $env:PWD = $appDir
  Ensure-GitOnPath

  New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
  if (-not (Test-Path $electronExe)) { throw "electron.exe not found: $electronExe" }
  # Avoid console logging: Electron will write to the parent console when --enable-logging is set.
  Start-Process -FilePath $electronExe -ArgumentList "$appDir", "--user-data-dir=`"$userDataDir`"", "--disk-cache-dir=`"$cacheDir`"" -WindowStyle Hidden | Out-Null
}

$exitCode = 0
if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) {
  try { $exitCode = $LASTEXITCODE } catch { $exitCode = 0 }
}
exit $exitCode
