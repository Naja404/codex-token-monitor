using System.Text.Json;
using CodexMonitor;

void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); }
foreach (var plan in new[] { "free", "plus", "pro", "enterprise", "team", "business", "edu", "future" })
{
    var parsed = Usage.Parse(JsonSerializer.Serialize(new { plan_type = plan }));
    Check(!string.IsNullOrEmpty(parsed.Plan) && !parsed.CanWrite, "plan without windows: " + plan);
}
var pro = Usage.Parse("""
{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1800000000}},
 "additional_rate_limits":[{"limit_name":"Model quota","normal_model_slug":"example-model","rate_limit":{
 "primary_window":{"used_percent":27,"limit_window_seconds":18000,"reset_at":1800000000},
 "secondary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_at":1800000000}}}]}
""");
Check(pro.Account.FiveHour == null && pro.Account.Weekly?.Remaining == 88, "account weekly is not replaced by model quota");
Check(pro.Additional[0].FiveHour?.Remaining == 73 && pro.Additional[0].Name.Contains("example-model"), "additional model identity and quota");
var dual = Usage.Parse("""
{"plan_type":"plus","rate_limit":{
"primary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_at":1800000000},
"secondary_window":{"used_percent":73,"limit_window_seconds":18000,"reset_at":1800000000}}}
""");
Check(dual.Account.FiveHour?.Remaining == 27 && dual.Account.Weekly?.Remaining == 82, "windows selected by duration");
var config = new WriteConfig("https://example.com/usage", "secret-not-in-body", "codex-example", 1, true);
var payload = JsonSerializer.Serialize(Writer.Payload(config, dual));
using var doc = JsonDocument.Parse(payload);
Check(doc.RootElement.GetProperty("five_hour").GetProperty("remaining_percent").GetInt32() == 27 && !payload.Contains(config.Bearer), "write-back payload and no bearer in body");
Check(doc.RootElement.GetProperty("seven_day").TryGetProperty("reset_date", out _) && doc.RootElement.GetProperty("codex_key_id").GetString() == config.KeyId, "write-back schema");
bool rejected = false;
try { Writer.Payload(config, pro); } catch (InvalidDataException) { rejected = true; }
Check(rejected, "partial account quota cannot be posted");
var state = new WriteState(); var now = DateTimeOffset.Now;
Check(state.Due(config, dual, now) && !state.Due(config, pro, now), "schedule requires complete account windows");
state.LastAttempt = now;
Check(!state.Due(config, dual, now.AddSeconds(59)) && state.Due(config, dual, now.AddMinutes(1)), "schedule respects interval");
for (var i = 0; i < 10; i++) state.Record(false, now);
Check(state.Paused && !state.Due(config, dual, now.AddHours(1)), "ten failures pause writing");
state.Record(true, now);
Check(!state.Paused && state.LastSuccess == now, "success resets failure state");
Check(!state.Due(config with { Enabled = false }, dual, now.AddHours(1)), "disabled automatic writing stays disabled");
using var handler = new CaptureHandler();
using var http = new HttpClient(handler);
await Writer.SendAsync(http, config with { Bearer = "Bearer example-secret" }, dual);
Check(handler.Authorization == "Bearer example-secret" && handler.Method == HttpMethod.Post, "POST uses a single bearer prefix");
Check(handler.Body != null && !handler.Body.Contains("example-secret"), "HTTP request body excludes credentials");
handler.Code = System.Net.HttpStatusCode.Unauthorized;
bool failedHttp = false;
try { await Writer.SendAsync(http, config, dual); } catch (InvalidDataException) { failedHttp = true; }
Check(failedHttp, "HTTP failure is surfaced to write-back state");
Console.WriteLine("All Windows core checks passed.");

sealed class CaptureHandler : HttpMessageHandler
{
    public string? Authorization, Body;
    public HttpMethod? Method;
    public System.Net.HttpStatusCode Code = System.Net.HttpStatusCode.OK;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        Authorization = request.Headers.Authorization?.ToString();
        Method = request.Method;
        Body = request.Content == null ? null : await request.Content.ReadAsStringAsync(token);
        return new HttpResponseMessage(Code);
    }
}
