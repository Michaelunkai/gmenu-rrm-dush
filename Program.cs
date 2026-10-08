using System;
using System.Collections.Generic;
using System.IO;

internal static class Program
{
    private static int Main(string[] args)
    {
        var targets = new List<string>(); var dryRun = false;
        foreach (var arg in args)
        {
            if (arg.Equals("--dry-run", StringComparison.OrdinalIgnoreCase)) { dryRun = true; continue; }
            if (arg.Equals("--force", StringComparison.OrdinalIgnoreCase) || arg.Equals("--kill-lockers", StringComparison.OrdinalIgnoreCase) || arg.Equals("--success-pending", StringComparison.OrdinalIgnoreCase)) continue;
            if (targets.Count == 0 && arg.Equals("delete", StringComparison.OrdinalIgnoreCase)) continue;
            targets.Add(arg);
        }
        if (targets.Count == 0) { Console.Error.WriteLine("Usage: ForceDeleteAnything.exe [--dry-run] <path> [...]"); return 2; }
        var failed = 0;
        foreach (var raw in targets)
        {
            var path = Path.GetFullPath(raw);
            if (!File.Exists(path) && !Directory.Exists(path)) { Console.Error.WriteLine("MISSING " + path); failed++; continue; }
            if (dryRun) { Console.WriteLine("DRY-RUN " + path); continue; }
            try { DeletePath(path); if (File.Exists(path) || Directory.Exists(path)) { Console.WriteLine("FAILED " + path); failed++; } else Console.WriteLine("DONE " + path); }
            catch (Exception ex) { Console.Error.WriteLine("FAILED " + path + ": " + ex.Message); failed++; }
        }
        try { var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ForceDeleteAnything", "logs"); Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "last-run.txt"), DateTime.UtcNow.ToString("o") + " dryRun=" + dryRun + " failed=" + failed); } catch { }
        return failed == 0 ? 0 : 1;
    }
    private static void DeletePath(string path)
    {
        if (File.Exists(path)) { File.SetAttributes(path, FileAttributes.Normal); File.Delete(path); return; }
        var info = new DirectoryInfo(path);
        if ((info.Attributes & FileAttributes.ReparsePoint) != 0) { info.Delete(false); return; }
        foreach (var file in info.GetFiles()) { try { file.IsReadOnly = false; file.Delete(); } catch { File.Delete(file.FullName); } }
        foreach (var child in info.GetDirectories()) { if ((child.Attributes & FileAttributes.ReparsePoint) == 0) DeletePath(child.FullName); }
        info.Delete(false);
    }
}
