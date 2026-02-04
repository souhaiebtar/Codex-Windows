param(
  [Parameter(Mandatory = $true)][string]$WorkRoot,
  [Parameter(Mandatory = $true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-StableId([string]$Prefix, [string]$Text) {
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha1.ComputeHash($bytes)
  } finally {
    $sha1.Dispose()
  }
  $hex = -join ($hash[0..11] | ForEach-Object { $_.ToString("x2") })
  return "${Prefix}_${hex}"
}

function Add-PathNode($root, [string[]]$parts) {
  $node = $root
  foreach ($p in $parts) {
    if (-not $node.Children.ContainsKey($p)) {
      $node.Children[$p] = [pscustomobject]@{
        Name     = $p
        Children = @{}
        Files    = @()
      }
    }
    $node = $node.Children[$p]
  }
  return $node
}

function Emit-Dir([System.Text.StringBuilder]$sb, $node, [string]$relPath, [int]$indent) {
  $pad = " " * $indent
  foreach ($childName in ($node.Children.Keys | Sort-Object)) {
    $child = $node.Children[$childName]
    $childRel = if ($relPath) { Join-Path $relPath $childName } else { $childName }
    $dirId = New-StableId "DIR" $childRel
    [void]$sb.AppendLine("$pad<Directory Id=""$dirId"" Name=""$($child.Name)"">")
    Emit-Dir $sb $child $childRel ($indent + 2)
    Emit-Files $sb $child $childRel ($indent + 2) $dirId
    [void]$sb.AppendLine("$pad</Directory>")
  }
}

function Emit-Files([System.Text.StringBuilder]$sb, $node, [string]$relPath, [int]$indent, [string]$directoryId) {
  $pad = " " * $indent
  foreach ($fileRel in ($node.Files | Sort-Object)) {
    $cmpId = New-StableId "CMP" $fileRel
    $fileId = New-StableId "FIL" $fileRel
    $src = '$(var.WorkPayloadSource)\' + ($fileRel -replace '/', '\')
    [void]$sb.AppendLine("$pad<Component Id=""$cmpId"" Guid=""*"">")
    [void]$sb.AppendLine("$pad  <File Id=""$fileId"" Source=""$src"" KeyPath=""yes"" />")
    [void]$sb.AppendLine("$pad</Component>")
  }
}

if (-not (Test-Path -Path $WorkRoot -PathType Container)) {
  throw "WorkRoot not found: $WorkRoot"
}

$payloadRoots = @("app", "native-builds")
foreach ($r in $payloadRoots) {
  $p = Join-Path $WorkRoot $r
  if (-not (Test-Path -Path $p -PathType Container)) {
    throw "Missing payload folder: $p"
  }
}

$tree = [pscustomobject]@{
  Name     = ""
  Children = @{}
  Files    = @()
}

$fileList = @()
foreach ($root in $payloadRoots) {
  $base = Join-Path $WorkRoot $root
  Get-ChildItem -Path $base -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($WorkRoot.Length).TrimStart('\','/')
    $rel = $rel -replace '/', '\'
    $fileList += $rel
  }
}

foreach ($rel in $fileList) {
  $parts = $rel.Split('\')
  $dirParts = $parts[0..($parts.Length - 2)]
  $node = Add-PathNode $tree $dirParts
  $node.Files += $rel
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
[void]$sb.AppendLine('  <Fragment>')
[void]$sb.AppendLine('    <DirectoryRef Id="WORKDIR">')

Emit-Dir $sb $tree "" 6

[void]$sb.AppendLine('    </DirectoryRef>')
[void]$sb.AppendLine('  </Fragment>')

[void]$sb.AppendLine('  <Fragment>')
[void]$sb.AppendLine('    <ComponentGroup Id="WorkPayload">')

# ComponentRefs: re-walk file list (stable order)
foreach ($rel in ($fileList | Sort-Object)) {
  $cmpId = New-StableId "CMP" $rel
  [void]$sb.AppendLine("      <ComponentRef Id=""$cmpId"" />")
}

[void]$sb.AppendLine('    </ComponentGroup>')
[void]$sb.AppendLine('  </Fragment>')
[void]$sb.AppendLine('</Wix>')

$dir = Split-Path $OutPath -Parent
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -Path $OutPath -Encoding UTF8 -NoNewline -Value $sb.ToString()
