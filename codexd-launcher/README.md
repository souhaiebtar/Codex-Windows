# CodexDesktop.exe (no-terminal launcher)

Build a Windows GUI executable that launches the already-extracted Codex desktop app without attaching to a terminal.

## Build

```powershell
dotnet publish .\codexd-launcher\CodexdLauncher.csproj -c Release -r win-x64 -p:PublishSingleFile=true -p:SelfContained=true
```

Output:

`codexd-launcher\bin\Release\net8.0-windows\win-x64\publish\CodexDesktop.exe`

## Usage

- Default work dir: `work` folder next to `CodexDesktop.exe`
- Override:

```powershell
CodexDesktop.exe --workdir C:\path\to\work
```

Optional (if auto-detection fails):

```powershell
CodexDesktop.exe --codex-cli-path C:\path\to\codex.exe
```

To force PowerShell 7 as the in-app terminal on Windows, set:

```powershell
$env:CODEX_PWSH_PATH = "C:\Program Files\PowerShell\7\pwsh.exe"
```

If something is misconfigured, the launcher shows a dialog (since there is no console).
