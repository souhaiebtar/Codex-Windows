using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            var workDir = Path.Combine(AppContext.BaseDirectory, "work");
            string? codexCliPath = null;

            for (var i = 0; i < args.Length; i++)
            {
                var a = args[i];
                if (a is "--workdir" or "--work-dir" or "--codex-desktop-path")
                {
                    if (i + 1 >= args.Length) throw new ArgumentException($"{a} requires a path value.");
                    workDir = args[++i];
                    continue;
                }

                if (a is "--codex-cli-path")
                {
                    if (i + 1 >= args.Length) throw new ArgumentException($"{a} requires a path value.");
                    codexCliPath = args[++i];
                    continue;
                }
            }

            if (!Directory.Exists(workDir))
                throw new DirectoryNotFoundException($"CodexDesktopPath not found: {workDir}\n\nChange it with: codexd.exe --workdir <path>\n(or create the directory).");

            var appDir = Path.Combine(workDir, "app");
            var nativeDir = Path.Combine(workDir, "native-builds");
            var userDataDir = Path.Combine(workDir, "userdata");
            var cacheDir = Path.Combine(workDir, "cache");
            Directory.CreateDirectory(userDataDir);
            Directory.CreateDirectory(cacheDir);

            var pkgPath = Path.Combine(appDir, "package.json");
            if (!File.Exists(pkgPath))
                throw new FileNotFoundException($"No extracted app found.\nExpected: {pkgPath}\n\nThis launcher assumes you already extracted the app into {appDir}.", pkgPath);

            PatchPreload(appDir);

            using var pkgDoc = JsonDocument.Parse(File.ReadAllText(pkgPath));
            var root = pkgDoc.RootElement;
            var electronVersion = root.GetProperty("devDependencies").GetProperty("electron").GetString();
            if (string.IsNullOrWhiteSpace(electronVersion))
                throw new InvalidOperationException("Electron version not found in app/package.json.");

            var electronExe = Path.Combine(nativeDir, "node_modules", "electron", "dist", "electron.exe");
            if (!File.Exists(electronExe))
                throw new FileNotFoundException($"electron.exe not found.\nExpected: {electronExe}\n\nRun the native-module prep step once (e.g. via codexd.ps1) to populate native-builds.", electronExe);

            var cli = ResolveCodexCliPath(codexCliPath);
            if (string.IsNullOrWhiteSpace(cli))
                throw new FileNotFoundException("codex.exe not found. Set CODEX_CLI_PATH, pass --codex-cli-path, or install Codex CLI so it is discoverable in PATH.");

            var rendererUrl = new Uri(Path.Combine(appDir, "webview", "index.html")).AbsoluteUri;

            var buildNumber = GetOptionalString(root, "codexBuildNumber") ?? "510";
            var buildFlavor = GetOptionalString(root, "codexBuildFlavor") ?? "prod";

            var psi = new ProcessStartInfo
            {
                FileName = electronExe,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = appDir,
            };
            psi.ArgumentList.Add(appDir);
            psi.ArgumentList.Add("--user-data-dir=" + userDataDir);
            psi.ArgumentList.Add("--disk-cache-dir=" + cacheDir);

            psi.Environment["ELECTRON_RENDERER_URL"] = rendererUrl;
            psi.Environment["ELECTRON_FORCE_IS_PACKAGED"] = "1";
            psi.Environment["CODEX_BUILD_NUMBER"] = buildNumber;
            psi.Environment["CODEX_BUILD_FLAVOR"] = buildFlavor;
            psi.Environment["BUILD_FLAVOR"] = buildFlavor;
            psi.Environment["NODE_ENV"] = "production";
            psi.Environment["CODEX_CLI_PATH"] = cli;
            psi.Environment["PWD"] = appDir;
            var pwsh = ResolvePwshPath();
            if (!string.IsNullOrWhiteSpace(pwsh))
                psi.Environment["COMSPEC"] = pwsh;

            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "codexd", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void PatchPreload(string appDir)
    {
        var preload = Path.Combine(appDir, ".vite", "build", "preload.js");
        if (!File.Exists(preload)) return;

        var raw = File.ReadAllText(preload);
        const string processExpose =
            "const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld(\"process\",P);";

        if (raw.Contains(processExpose, StringComparison.Ordinal)) return;

        var re = new Regex(
            "n\\.contextBridge\\.exposeInMainWorld\\(\"codexWindowType\",[A-Za-z0-9_$]+\\);n\\.contextBridge\\.exposeInMainWorld\\(\"electronBridge\",[A-Za-z0-9_$]+\\);",
            RegexOptions.Compiled);

        var m = re.Match(raw);
        if (!m.Success) throw new InvalidOperationException("preload patch point not found.");

        raw = raw.Replace(m.Value, processExpose + m.Value, StringComparison.Ordinal);
        File.WriteAllText(preload, raw);
    }

    private static string? ResolveCodexCliPath(string? explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            if (File.Exists(explicitPath) && Path.GetExtension(explicitPath).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(explicitPath);
            throw new FileNotFoundException($"Codex CLI not found: {explicitPath}", explicitPath);
        }

        var bundledCli1 = Path.Combine(AppContext.BaseDirectory, "codex.exe");
        if (File.Exists(bundledCli1)) return bundledCli1;
        var bundledCli2 = Path.Combine(AppContext.BaseDirectory, "cli", "codex.exe");
        if (File.Exists(bundledCli2)) return bundledCli2;

        var envOverride = Environment.GetEnvironmentVariable("CODEX_CLI_PATH");
        if (!string.IsNullOrWhiteSpace(envOverride) &&
            File.Exists(envOverride) &&
            Path.GetExtension(envOverride).Equals(".exe", StringComparison.OrdinalIgnoreCase))
            return Path.GetFullPath(envOverride);

        var candidates = new List<string>();

        // Prefer the global npm install location (common when launching from Explorer,
        // where PATH may differ from a terminal session).
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (!string.IsNullOrWhiteSpace(appData))
        {
            var npmRootGuess = Path.Combine(appData, "npm", "node_modules");
            candidates.AddRange(FindVendorCodexExeCandidates(npmRootGuess));
        }

        try
        {
            candidates.AddRange(RunWhere("codex.exe"));
            candidates.AddRange(RunWhere("codex"));
        }
        catch
        {
            // ignore
        }

        try
        {
            var npmRoot = RunCapture("npm", "root -g")?.Trim();
            if (!string.IsNullOrWhiteSpace(npmRoot))
            {
                candidates.AddRange(FindVendorCodexExeCandidates(npmRoot));
            }
        }
        catch
        {
            // ignore
        }

        foreach (var c in candidates)
        {
            if (string.IsNullOrWhiteSpace(c)) continue;

            // Only accept a real executable; npm shims like "...\\npm\\codex" or "...\\codex.cmd"
            // are not spawnable by the Electron app without shell wrapping.
            if (File.Exists(c) && Path.GetExtension(c).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(c);

            // If we found a shim, try to resolve to the real vendor binary nearby.
            if (File.Exists(c) && (c.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ||
                                   c.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase) ||
                                   string.IsNullOrEmpty(Path.GetExtension(c))))
            {
                var binDir = Path.GetDirectoryName(c);
                if (!string.IsNullOrWhiteSpace(binDir))
                {
                    var npmRootFromBin = Path.Combine(binDir, "node_modules");
                    foreach (var exe in FindVendorCodexExeCandidates(npmRootFromBin))
                    {
                        if (File.Exists(exe)) return Path.GetFullPath(exe);
                    }
                }
            }
        }

        return null;
    }

    private static string? ResolvePwshPath()
    {
        var envOverride = Environment.GetEnvironmentVariable("CODEX_PWSH_PATH");
        if (!string.IsNullOrWhiteSpace(envOverride) && File.Exists(envOverride))
            return Path.GetFullPath(envOverride);

        var candidates = new List<string>();
        try
        {
            candidates.AddRange(RunWhere("pwsh.exe"));
        }
        catch
        {
        }

        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(pf))
        {
            candidates.Add(Path.Combine(pf, "PowerShell", "7", "pwsh.exe"));
            candidates.Add(Path.Combine(pf, "PowerShell", "7-preview", "pwsh.exe"));
        }

        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        if (!string.IsNullOrWhiteSpace(pf86))
        {
            candidates.Add(Path.Combine(pf86, "PowerShell", "7", "pwsh.exe"));
            candidates.Add(Path.Combine(pf86, "PowerShell", "7-preview", "pwsh.exe"));
        }

        foreach (var c in candidates)
        {
            if (string.IsNullOrWhiteSpace(c)) continue;
            if (File.Exists(c)) return Path.GetFullPath(c);
        }

        return null;
    }

    private static IEnumerable<string> FindVendorCodexExeCandidates(string npmRoot)
    {
        if (string.IsNullOrWhiteSpace(npmRoot)) yield break;

        var vendor = Path.Combine(npmRoot, "@openai", "codex", "vendor");
        if (!Directory.Exists(vendor)) yield break;

        var arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") == "ARM64"
            ? "aarch64-pc-windows-msvc"
            : "x86_64-pc-windows-msvc";

        // Prefer current arch first, then the other common one.
        yield return Path.Combine(vendor, arch, "codex", "codex.exe");
        yield return Path.Combine(vendor, "x86_64-pc-windows-msvc", "codex", "codex.exe");
        yield return Path.Combine(vendor, "aarch64-pc-windows-msvc", "codex", "codex.exe");
    }

    private static IEnumerable<string> RunWhere(string name)
    {
        var output = RunCapture("where.exe", name);
        if (string.IsNullOrWhiteSpace(output)) yield break;
        foreach (var line in output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
            yield return line.Trim();
    }

    private static string? RunCapture(string fileName, string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        using var p = Process.Start(psi);
        if (p == null) return null;
        var stdout = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        return stdout;
    }

    private static string? GetOptionalString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind == JsonValueKind.String) return v.GetString();
        return v.ToString();
    }
}
