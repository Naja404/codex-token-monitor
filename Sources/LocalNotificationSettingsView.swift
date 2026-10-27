import AppKit
import SwiftUI

struct LocalNotificationSettingsView: View {
    @ObservedObject var controller: LocalNotificationController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(L10n.text("启用本地通知"), isOn: Binding(get: { controller.preferences.enabled }, set: { enabled in
                Task { await controller.setEnabled(enabled) }
            })).disabled(controller.requestingPermission)
            Text(controller.authorization.title).font(.caption).monitorSecondary()
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("通知类别")).font(.headline)
                ForEach(LocalAlertKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(get: { controller.preferences.kinds.contains(kind) }, set: { selected in
                        controller.update { p in
                            if selected { p.kinds.insert(kind) } else { p.kinds.remove(kind) }
                        }
                    }))
                }
                Text(L10n.text("临时刷新失败连续发生 3 次才提醒；登录失效或刷新已暂停时可立即提醒。恢复提醒需先观察到低额度。"))
                    .font(.caption).monitorSecondary()
            }
            Divider()
            Stepper(value: Binding(get: { controller.preferences.percentThreshold }, set: { value in
                controller.update { $0.percentThreshold = value }
            }), in: 0...95, step: 5) {
                Text(L10n.format("剩余百分比 ≤ %d%% 时提醒", Int(controller.preferences.percentThreshold)))
            }
            Stepper(value: Binding(get: { controller.preferences.balanceThreshold }, set: { value in
                controller.update { $0.balanceThreshold = value }
            }), in: 0...1000, step: 0.5) {
                Text(L10n.format("TeamoRouter 余额 ≤ $%.2f 时提醒", controller.preferences.balanceThreshold))
            }
            Text(L10n.text("恢复后才重新允许低额度提醒：百分比需高于阈值至少 5 个百分点；余额需高于阈值至少 $0.50 或阈值的 10%。"))
                .font(.caption).monitorSecondary()
            Toggle(L10n.text("播放通知声音"), isOn: Binding(get: { controller.preferences.sound }, set: { value in
                controller.update { $0.sound = value }
            }))
            HStack(spacing: 12) {
                Button(L10n.text("发送测试通知")) { Task { await controller.sendTest() } }
                    .disabled(!controller.preferences.enabled || controller.requestingPermission)
                Button(L10n.text("刷新权限状态")) { Task { await controller.refreshAuthorization() } }
                Button(L10n.text("打开系统设置")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }.buttonStyle(.bordered)
            if let message = controller.message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Text(L10n.text("仅提醒已启用的供应商。相同事件不会反复通知，重启后保留去重状态；通知不包含密钥。显示方式由 macOS 通知设置和专注模式决定，应用退出后不再监测。"))
                .font(.caption).monitorSecondary()
        }.padding(16).monitorSurface()
        .task { await controller.refreshAuthorization() }
    }
}
