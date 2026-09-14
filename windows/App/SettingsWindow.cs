using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using CodexMonitor;

namespace CodexMonitorWindows;

internal sealed class SettingsWindow : System.Windows.Window
{
    private readonly TextBlock status = UI.Text("", 12);
    public void UpdateStatus(string value) => status.Text = value;

    public SettingsWindow(WriteConfig current, Action<WriteConfig> save, Func<WriteConfig, Task<string>> verify)
    {
        Title = "Codex Token Monitor · 回写设置";
        Width = 460; Height = 610; MinWidth = 380; MinHeight = 450;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new StackPanel { Margin = new Thickness(22) };
        root.Children.Add(UI.Text("定时回写额度", 22, true));
        var enabled = new CheckBox { Content = "开启自动回写", IsChecked = current.Enabled, Margin = new Thickness(0, 10, 0, 12) };
        root.Children.Add(enabled);
        TextBox Field(string label, string value) {
            root.Children.Add(UI.Text(label));
            var field = new TextBox { Text = value, Padding = new Thickness(8), Margin = new Thickness(0, 0, 0, 10) };
            root.Children.Add(field);
            return field;
        }
        var interval = Field("间隔（1–60 分钟，默认 1 分钟）", current.Minutes.ToString());
        var url = Field("API 地址", current.Url);
        root.Children.Add(UI.Text("API Bearer"));
        var bearer = new PasswordBox { Password = current.Bearer, Padding = new Thickness(8), Margin = new Thickness(0, 0, 0, 10) };
        root.Children.Add(bearer);
        var key = Field("Codex Key ID", current.KeyId);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        WriteConfig Draft() {
            if (!int.TryParse(interval.Text, out var minutes)) throw new InvalidDataException("请输入 1–60 的整数间隔");
            return new(url.Text.Trim(), bearer.Password.Trim(), key.Text.Trim(), minutes, enabled.IsChecked == true);
        }
        buttons.Children.Add(UI.Button("保存配置", () => {
            try {
                var draft = Draft();
                // Disabling must remain possible even with an incomplete endpoint.
                if (draft.Enabled) draft.Validate();
                else if (draft.Minutes is < 1 or > 60) throw new InvalidDataException("间隔应为 1–60 分钟");
                save(draft); status.Text = "配置已保存，连续失败计数已清零";
            }
            catch (Exception error) { status.Text = error is InvalidDataException ? error.Message : "保存失败，请检查本地文件权限"; }
        }));
        buttons.Children.Add(UI.Button("验证连接", async () => {
            buttons.IsEnabled = false;
            try { var draft = Draft(); draft.Validate(); status.Text = "正在验证…"; status.Text = await verify(draft); }
            catch (Exception error) { status.Text = error is InvalidDataException ? error.Message : "验证失败"; }
            finally { buttons.IsEnabled = true; }
        }));
        root.Children.Add(buttons);
        root.Children.Add(UI.Text("验证会向当前地址发送一次真实账户额度，不保存草稿、不计入失败次数。连续回写失败 10 次后暂停，重新保存配置可恢复。", 12));
        root.Children.Add(status);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}
