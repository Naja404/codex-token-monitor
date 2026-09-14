using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexMonitor;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;
using Window = CodexMonitor.Window;

namespace CodexMonitorWindows;

internal sealed class Program : Application
{
    private readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(20) };
    private readonly Forms.NotifyIcon tray = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly System.Windows.Window popup = new() {
        Width = 360, Height = 540, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
        ShowInTaskbar = false, Topmost = true, Background = Brushes.WhiteSmoke
    };
    private WriteConfig config = new();
    private WriteState writeState = new();
    private Usage? usage;
    private DateTimeOffset? refreshed;
    private string status = "正在读取额度…";
    private string writeStatus = "";
    private bool refreshing, writing;
    private int configVersion;
    private SettingsWindow? settings;

    [STAThread]
    public static void Main()
    {
        using var mutex = new Mutex(true, @"Local\CodexTokenMonitor.Windows", out var first);
        if (!first) return;
        new Program().Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        try { (config, writeState) = Store.Load(); }
        catch { writeStatus = "回写配置无法读取，自动回写已关闭，请重新保存配置"; }
        popup.Deactivated += (_, _) => popup.Hide();
        popup.PreviewKeyDown += (_, args) => { if (args.Key == System.Windows.Input.Key.Escape) popup.Hide(); };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示额度", null, (_, _) => ShowPopup());
        menu.Items.Add("刷新", null, async (_, _) => await Refresh());
        menu.Items.Add("回写设置", null, (_, _) => OpenSettings());
        menu.Items.Add("退出", null, (_, _) => Shutdown());
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (_, args) => { if (args.Button == Forms.MouseButtons.Left) { if (popup.IsVisible) popup.Hide(); else ShowPopup(); } };
        UpdateTray();
        tray.Visible = true;
        timer.Tick += async (_, _) => await Refresh();
        timer.Start();
        _ = Refresh();
    }

    private async Task Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        status = "正在读取额度…";
        Render();
        try {
            usage = await new UsageClient(http).ReadAsync();
            refreshed = DateTimeOffset.Now;
            status = "已直连 OpenAI · " + usage.Plan;
        }
        catch (Exception error) { usage = null; status = ErrorText(error); }
        finally { refreshing = false; UpdateTray(); Render(); }
        if (writeState.Due(config, usage, DateTimeOffset.Now)) await Write(config, false);
    }

    private static string ErrorText(Exception error) => error switch {
        InvalidDataException => error.Message,
        TaskCanceledException => "请求超时，请检查网络后重试",
        HttpRequestException => "网络请求失败，请检查网络或代理",
        _ => "无法读取数据，请检查登录凭据或响应格式"
    };

    private async Task<string> Write(WriteConfig draft, bool verify)
    {
        if (writing) return "正在回写，请稍后重试";
        if (refreshing || usage == null || !usage.CanWrite) return "需要成功读取账户的 5 小时及每周窗口后才能回写";
        writing = true;
        var version = configVersion;
        if (!verify) writeState.LastAttempt = DateTimeOffset.Now;
        bool success = false;
        string message;
        try { await Writer.SendAsync(http, draft, usage); success = true; message = verify ? "验证成功，已实际发送一次额度" : "回写成功"; }
        catch (Exception error) { message = ErrorText(error); }
        if (!verify && version == configVersion) {
            writeState.Record(success, DateTimeOffset.Now);
            try { Store.Save(config, writeState); }
            catch { config = config with { Enabled = false }; message += "；保存状态失败，自动回写已关闭"; }
        }
        writing = false;
        writeStatus = message;
        Render();
        settings?.UpdateStatus(WriteSummary());
        return message;
    }

    private string WriteSummary() =>
        $"最近成功：{writeState.LastSuccess?.LocalDateTime.ToString("M月d日 HH:mm:ss") ?? "暂无"}\n" +
        (writeState.Paused ? "连续失败 10 次，自动回写已暂停，请修改配置后保存" :
            $"自动回写：{(config.Enabled ? $"每 {config.Minutes} 分钟" : "关闭")} · 连续失败 {writeState.Failures} 次") +
        (config.Enabled && usage?.CanWrite != true ? "\n等待完整账户窗口，暂不回写" : "") +
        (writeStatus.Length > 0 ? "\n" + writeStatus : "");

    private void OpenSettings()
    {
        popup.Hide();
        if (settings != null) { settings.Activate(); return; }
        settings = new SettingsWindow(config, draft => {
            if (writing) throw new InvalidDataException("正在回写，请等待完成后再保存");
            var state = new WriteState { LastSuccess = writeState.LastSuccess };
            Store.Save(draft, state);
            configVersion++;
            config = draft;
            writeState = state;
            writeStatus = "配置已保存";
            Render();
        }, draft => Write(draft, true));
        settings.UpdateStatus(WriteSummary());
        settings.Closed += (_, _) => settings = null;
        settings.Show();
        settings.Activate();
    }

    private void ShowPopup()
    {
        // Screen and cursor use physical pixels; SetWindowPos uses the same coordinate system.
        var point = Forms.Cursor.Position;
        var work = Forms.Screen.FromPoint(point).WorkingArea;
        Render();
        popup.Show();
        var handle = new WindowInteropHelper(popup).Handle;
        void Position() {
            GetWindowRect(handle, out var rect);
            var width = Math.Min(rect.Right - rect.Left, work.Width);
            var height = Math.Min(rect.Bottom - rect.Top, work.Height);
            var left = Math.Clamp(point.X - width / 2, work.Left, work.Right - width);
            var top = Math.Clamp(point.Y - height - 8, work.Top, work.Bottom - height);
            SetWindowPos(handle, IntPtr.Zero, left, top, width, height, 0x0004);
        }
        Position();
        popup.Activate();
        // Re-evaluate after WPF processes a possible per-monitor DPI change.
        popup.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => { if (popup.IsVisible) Position(); }));
    }

    private void Render()
    {
        var root = new StackPanel { Margin = new Thickness(18) };
        root.Children.Add(UI.Text("Codex Token Monitor", 19, true));
        root.Children.Add(UI.Text(status));
        root.Children.Add(UI.Text("最近读取：" + (refreshed?.LocalDateTime.ToString("HH:mm:ss") ?? "—")));
        root.Children.Add(QuotaCard("5 小时额度", usage?.Account.FiveHour));
        root.Children.Add(QuotaCard("每周额度", usage?.Account.Weekly));
        if (usage != null) foreach (var extra in usage.Additional) {
            root.Children.Add(UI.Text("附加额度 · " + extra.Name, 12, true));
            root.Children.Add(UI.Text($"5 小时：{Describe(extra.FiveHour)}\n每周：{Describe(extra.Weekly)}", 12));
        }
        var buttons = new WrapPanel();
        buttons.Children.Add(UI.Button("刷新", async () => await Refresh()));
        buttons.Children.Add(UI.Button("回写设置", OpenSettings));
        buttons.Children.Add(UI.Button("立即回写", async () => { writeStatus = await Write(config, false); Render(); }));
        root.Children.Add(buttons);
        root.Children.Add(UI.Text(WriteSummary(), 12));
        root.Children.Add(UI.Button("退出", () => Shutdown()));
        popup.Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private Border QuotaCard(string name, Window? window)
    {
        var content = new StackPanel();
        content.Children.Add(UI.Text(name + " · " + (window == null ? "—" : $"{window.Remaining}% 剩余"), 15, true));
        content.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = window?.Remaining ?? 0, Height = 6, Margin = new Thickness(0, 6, 0, 8), Foreground = Tone(window?.Remaining) });
        content.Children.Add(UI.Text(window == null ? usage == null ? "暂未读取到额度" : "接口未提供此窗口" : "重置：" + window.Reset.LocalDateTime.ToString("M月d日 HH:mm"), 12));
        return new Border { Child = content, CornerRadius = new CornerRadius(10), Padding = new Thickness(14), Margin = new Thickness(0, 10, 0, 0), Background = Brushes.White };
    }
    private static string Describe(Window? window) => window == null ? "未提供" : $"{window.Remaining}% 剩余，重置 {window.Reset.LocalDateTime:M月d日 HH:mm}";
    private static SolidColorBrush Tone(int? value) => new(value switch {
        >= 80 => Color.FromRgb(83, 143, 113), >= 50 => Color.FromRgb(183, 129, 71),
        >= 20 => Color.FromRgb(172, 152, 62), >= 0 => Color.FromRgb(192, 100, 100), _ => Colors.Gray
    });

    private void UpdateTray()
    {
        var value = usage?.Account.FiveHour ?? usage?.Account.Weekly;
        using var bitmap = new Drawing.Bitmap(32, 32);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.Clear(Drawing.Color.FromArgb(43, 52, 66));
        using var font = new Drawing.Font("Segoe UI", value?.Remaining == 100 ? 12 : 15, Drawing.FontStyle.Bold, Drawing.GraphicsUnit.Pixel);
        using var format = new Drawing.StringFormat { Alignment = Drawing.StringAlignment.Center, LineAlignment = Drawing.StringAlignment.Center };
        graphics.DrawString(value?.Remaining.ToString() ?? "—", font, Drawing.Brushes.White, new Drawing.RectangleF(0, 0, 32, 32), format);
        var handle = bitmap.GetHicon();
        using var borrowed = Drawing.Icon.FromHandle(handle);
        var icon = (Drawing.Icon)borrowed.Clone();
        DestroyIcon(handle);
        var old = tray.Icon;
        tray.Icon = icon;
        old?.Dispose();
        var label = usage == null ? "Codex：未读取到额度" : $"{usage.Plan} · 5小时 {usage.Account.FiveHour?.Remaining.ToString() ?? "—"}% / 每周 {usage.Account.Weekly?.Remaining.ToString() ?? "—"}%";
        tray.Text = label.Length > 63 ? label[..63] : label;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        timer.Stop();
        tray.Visible = false;
        tray.Icon?.Dispose();
        tray.ContextMenuStrip?.Dispose();
        tray.Dispose();
        http.Dispose();
        base.OnExit(e);
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
}

internal static class UI
{
    public static TextBlock Text(string value, double size = 13, bool bold = false) => new() {
        Text = value, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3), Foreground = Brushes.DarkSlateGray
    };
    public static Button Button(string title, Action action) {
        var button = new Button { Content = title, Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 10, 6, 4) };
        button.Click += (_, _) => action();
        return button;
    }
}
