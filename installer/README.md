# Installer

This builds a per-user MSI that installs:

- `CodexDesktop.exe` (the no-terminal launcher)
- `cli\codex.exe` (Codex CLI binary used by the desktop app)
- `work\app` + `work\native-builds` (the extracted desktop app + Electron/native deps)

Install location (per-user):

- `%LOCALAPPDATA%\codexd`

`CodexDesktop.exe` defaults to using the `work` folder next to it, so the installed app runs without extra flags.

## Build

Prereqs:

- .NET SDK
- The repo `work\app` and `work\native-builds` already populated
- A real `codex.exe` somewhere (not the npm shim). The script will try to auto-detect, or you can pass it.

Build:

One-shot (run `run.ps1` to populate `work/`, then build `CodexDesktop-setup.exe` only):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-setup-exe.ps1
```

Skip DMG re-extraction if `work/` is already populated:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-setup-exe.ps1 -Reuse
```


for `.exe`

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer-exe.ps1 -SingleFileInstaller
```

for `MSI`

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1
```

Optional:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1 -CodexCliExe C:\path\to\codex.exe
```

Output:

- `installer\out\CodexDesktop.msi`
- `installer\out\CodexDesktop-setup.exe` (single-file installer)

## Install / Run

- Double-click `installer\out\CodexDesktop-setup.exe` to install (per-user, no admin).
- You can also use `installer\out\CodexDesktop.msi` directly if preferred.
- After install, run `codex-desktop` from the Start Menu, or via Win+R `CodexDesktop` (it registers an App Paths entry).
