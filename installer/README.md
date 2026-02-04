# Installer

This builds a per-user MSI that installs:

- `codexd.exe` (the no-terminal launcher)
- `cli\codex.exe` (Codex CLI binary used by the desktop app)
- `work\app` + `work\native-builds` (the extracted desktop app + Electron/native deps)

Install location (per-user):

- `%LOCALAPPDATA%\codexd`

`codexd.exe` defaults to using the `work` folder next to it, so the installed app runs without extra flags.

## Build

Prereqs:

- .NET SDK
- The repo `work\app` and `work\native-builds` already populated
- A real `codex.exe` somewhere (not the npm shim). The script will try to auto-detect, or you can pass it.

Build:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1
```

Optional:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1 -CodexCliExe C:\path\to\codex.exe
```

Output:

- `installer\out\codexd.msi`

## Install / Run

- Double-click `installer\out\codexd.msi` to install.
- After install, run `codexd` from the Start Menu, or via Win+R `codexd` (it registers an App Paths entry).

