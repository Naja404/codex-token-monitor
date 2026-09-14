using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace CodexMonitor;

public record Window(int Remaining, DateTimeOffset Reset);
public record Quota(string Name, Window? FiveHour, Window? Weekly);
public record Usage(string Plan, Quota Account, IReadOnlyList<Quota> Additional)
{
    public bool CanWrite => Account.FiveHour != null && Account.Weekly != null;

    public static Usage Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            (!root.TryGetProperty("plan_type", out _) && !root.TryGetProperty("rate_limit", out _)))
            throw new InvalidDataException("接口未提供套餐或额度信息");
        var raw = Text(root, "plan_type");
        var plan = raw?.ToLowerInvariant() switch {
            "free" => "Free", "plus" => "Plus", "pro" => "Pro",
            "team" or "business" => "Business（企业工作区）",
            "enterprise" => "Enterprise（企业）", "edu" => "Edu（教育）",
            null or "" => "套餐未识别", _ => $"未知套餐（{raw}）"
        };
        var additional = new List<Quota>();
        if (root.TryGetProperty("additional_rate_limits", out var extras) && extras.ValueKind == JsonValueKind.Array)
            foreach (var item in extras.EnumerateArray())
            {
                var labels = new[] { Text(item, "limit_name"), Text(item, "normal_model_slug"), Text(item, "metered_feature") }
                    .Where(s => !string.IsNullOrWhiteSpace(s));
                var name = string.Join(" · ", labels);
                additional.Add(ReadQuota(item, name.Length > 0 ? name : "未命名附加额度"));
            }
        return new(plan, ReadQuota(root, "账户额度"), additional);
    }

    private static string? Text(JsonElement obj, string key) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    private static Quota ReadQuota(JsonElement parent, string name)
    {
        Window? five = null, week = null;
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty("rate_limit", out var rate) && rate.ValueKind == JsonValueKind.Object)
            foreach (var key in new[] { "primary_window", "secondary_window" })
            {
                if (!rate.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object ||
                    !w.TryGetProperty("limit_window_seconds", out var duration) || !duration.TryGetInt64(out var seconds) ||
                    !w.TryGetProperty("used_percent", out var percent) || !percent.TryGetDouble(out var used) || !double.IsFinite(used) ||
                    !w.TryGetProperty("reset_at", out var reset) || !reset.TryGetInt64(out var timestamp) || timestamp <= 0 || timestamp > 253402300799)
                    continue;
                var window = new Window(100 - (int)Math.Round(Math.Clamp(used, 0, 100), MidpointRounding.AwayFromZero), DateTimeOffset.FromUnixTimeSeconds(timestamp));
                if (seconds == 18000) five = window;
                if (seconds == 604800) week = window;
            }
        return new(name, five, week);
    }
}

public sealed class UsageClient(HttpClient http)
{
    public async Task<Usage> ReadAsync()
    {
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(codexHome))
            codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        var file = Path.Combine(codexHome, "auth.json");
        if (!File.Exists(file)) throw new InvalidDataException("请先在 Windows 上登录 Codex，生成 auth.json");
        using var auth = JsonDocument.Parse(await File.ReadAllTextAsync(file));
        if (!auth.RootElement.TryGetProperty("tokens", out var tokens) || tokens.ValueKind != JsonValueKind.Object ||
            !tokens.TryGetProperty("access_token", out var access) || access.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(access.GetString()))
            throw new InvalidDataException("需要 Codex 的 ChatGPT 登录凭据，API Key 登录不适用");
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://chatgpt.com/backend-api/wham/usage");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access.GetString());
        if (tokens.TryGetProperty("account_id", out var account) && account.ValueKind == JsonValueKind.String)
            request.Headers.Add("chatgpt-account-id", account.GetString());
        request.Headers.Add("originator", "codex_cli_rs");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
            throw new InvalidDataException($"读取失败：HTTP {(int)response.StatusCode}" + ((int)response.StatusCode == 401 ? "，请重新登录 Codex" : ""));
        return Usage.Parse(await response.Content.ReadAsStringAsync());
    }
}

public record WriteConfig(string Url = "", string Bearer = "", string KeyId = "", int Minutes = 1, bool Enabled = false)
{
    public void Validate()
    {
        if (!Uri.TryCreate(Url, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && uri.Scheme != "http") || !string.IsNullOrEmpty(uri.UserInfo))
            throw new InvalidDataException("请填写有效的 HTTP/HTTPS API 地址");
        if (string.IsNullOrWhiteSpace(Bearer) || Bearer.Contains('\r') || Bearer.Contains('\n') || string.IsNullOrWhiteSpace(KeyId))
            throw new InvalidDataException("请填写有效的 Bearer 和 Codex Key ID");
        if (Minutes is < 1 or > 60) throw new InvalidDataException("回写间隔应为 1–60 分钟");
    }
}

public sealed class WriteState
{
    public DateTimeOffset? LastSuccess { get; set; }
    public DateTimeOffset? LastAttempt { get; set; }
    public int Failures { get; set; }
    public bool Paused => Failures >= 10;
    public bool Due(WriteConfig config, Usage? usage, DateTimeOffset now) => config.Enabled && !Paused && usage?.CanWrite == true &&
        (LastAttempt == null || now - LastAttempt >= TimeSpan.FromMinutes(config.Minutes));
    public void Record(bool success, DateTimeOffset now)
    {
        if (success) { LastSuccess = now; Failures = 0; }
        else Failures++;
    }
}

public static class Writer
{
    public static object Payload(WriteConfig config, Usage usage)
    {
        if (!usage.CanWrite) throw new InvalidDataException("回写需要账户同时提供 5 小时和每周窗口；不会发送附加模型额度");
        return new {
            codex_key_id = config.KeyId,
            five_hour = new { remaining_percent = usage.Account.FiveHour!.Remaining, reset_time = usage.Account.FiveHour.Reset.LocalDateTime.ToString("HH:mm") },
            seven_day = new { remaining_percent = usage.Account.Weekly!.Remaining, reset_date = usage.Account.Weekly.Reset.LocalDateTime.ToString("M月d日 HH:mm") }
        };
    }
    public static async Task SendAsync(HttpClient http, WriteConfig config, Usage usage)
    {
        config.Validate();
        using var request = new HttpRequestMessage(HttpMethod.Post, config.Url);
        var bearer = config.Bearer.Trim();
        if (bearer.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) bearer = bearer[7..].Trim();
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
        request.Content = JsonContent.Create(Payload(config, usage));
        using var response = await http.SendAsync(request);
        if (!response.IsSuccessStatusCode) throw new InvalidDataException($"回写失败：HTTP {(int)response.StatusCode}");
    }
}
