using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CodexMonitor;

namespace CodexMonitorWindows;

internal sealed record Saved(WriteConfig Config, string ProtectedBearer, WriteState State);
internal static class Store
{
    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTokenMonitor");
    private static readonly string FileName = Path.Combine(Folder, "settings.json");
    public static (WriteConfig Config, WriteState State) Load()
    {
        if (!File.Exists(FileName)) return (new(), new());
        var saved = JsonSerializer.Deserialize<Saved>(File.ReadAllText(FileName)) ?? throw new InvalidDataException();
        var bearer = saved.ProtectedBearer.Length == 0 ? "" : Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(saved.ProtectedBearer), null, DataProtectionScope.CurrentUser));
        var config = saved.Config with { Bearer = bearer };
        if (config.Enabled) config.Validate();
        return (config, saved.State);
    }
    public static void Save(WriteConfig config, WriteState state)
    {
        Directory.CreateDirectory(Folder);
        var secret = config.Bearer.Length == 0 ? "" : Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(config.Bearer), null, DataProtectionScope.CurrentUser));
        var data = JsonSerializer.Serialize(new Saved(config with { Bearer = "" }, secret, state));
        var temporary = FileName + ".tmp";
        File.WriteAllText(temporary, data);
        File.Move(temporary, FileName, true);
    }
}
