# codexd.exe (no-terminal launcher)

Build a Windows GUI executable that launches the already-extracted Codex desktop app without attaching to a terminal.

## Build

```powershell
dotnet publish .\codexd-launcher\CodexdLauncher.csproj -c Release -r win-x64 -p:PublishSingleFile=true -p:SelfContained=true
```

Output:

`codexd-launcher\bin\Release\net8.0-windows\win-x64\publish\codexd.exe`

## Usage

- Default work dir: `work` folder next to `codexd.exe`
- Override:

```powershell
codexd.exe --workdir C:\path\to\work
```

Optional (if auto-detection fails):

```powershell
codexd.exe --codex-cli-path C:\path\to\codex.exe
```

If something is misconfigured, the launcher shows a dialog (since there is no console).
