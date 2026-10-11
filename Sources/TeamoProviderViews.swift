import SwiftUI

struct TeamoProviderSettings: View {
    @ObservedObject var store: ProviderStore
    @AppStorage("teamoBaseURL") private var savedBase = "https://api.teamorouter.com"
    @State private var baseDraft = "https://api.teamorouter.com"
    @State private var keyDraft = ""
    @State private var message: String?
    @State private var busy = false
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { store.teamoEnabled }, set: { store.setTeamoEnabled($0) })) {
                Label("TeamoRouter", systemImage: "arrow.triangle.branch").font(.headline)
            }.toggleStyle(.switch)
            SettingsDisclosure(title: L10n.text("连接与设置"), expanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Claude Code API 接入 · 账户余额 / 当前 Key 用量")).font(.subheadline)
                    Text(L10n.text("适用于 ANTHROPIC_BASE_URL 指向 TeamoRouter、使用 ANTHROPIC_AUTH_TOKEN 的 Claude Code。不需要 Claude 官方订阅或保持 CLI 运行。"))
                        .font(.caption).monitorSecondary()
                    Text(L10n.text("API 地址")).font(.caption.weight(.medium))
                    TextField("https://api.teamorouter.com", text: $baseDraft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("TeamoRouter API 地址")).disabled(busy)
                    Text("API Bearer").font(.caption.weight(.medium))
                    SecureField(L10n.text("留空保留已保存密钥"), text: $keyDraft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("TeamoRouter Bearer").disabled(busy)
                    HStack {
                        Button(L10n.text("从 .zshrc 导入")) { importConfiguration() }.buttonStyle(.bordered).disabled(busy)
                        Button(L10n.text("保存")) { saveConfiguration() }.buttonStyle(.bordered).disabled(busy)
                        Spacer()
                        Button(L10n.text("验证连接")) { store.refreshTeamo(allowInteraction: true) }.buttonStyle(.borderedProminent)
                            .disabled(busy || !keyDraft.isEmpty || baseDraft != savedBase || store.isRefreshingTeamo ||
                                      (store.teamoError == .rateLimited && Date() < store.nextTeamoRefresh))
                    }
                    if busy { ProgressView().controlSize(.small) }
                    if let message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    if let error = store.teamoError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                    if store.teamoError == .rateLimited {
                        Text(L10n.text("暂停至 ") + L10n.date(store.nextTeamoRefresh)).font(.caption)
                    }
                    if !keyDraft.isEmpty || baseDraft != savedBase {
                        Text(L10n.text("表单尚未保存；监控仍使用已保存配置。请先保存，再验证。"))
                            .font(.caption).monitorSecondary()
                    } else if store.isRefreshingTeamo {
                        Text(L10n.text("正在查询余额、今日消费和 Token…")).font(.caption).monitorSecondary()
                    } else if let quota = store.teamoSnapshot, let time = store.teamoLastSuccessAt {
                        Text(L10n.format("余额 %@ · 今日 %@ · %@ Tokens", quota.balanceText, quota.costText, quota.totalTokens.formatted()))
                            .font(.caption.weight(.medium)).textSelection(.enabled)
                        Text(L10n.text("验证成功于 ") + L10n.date(time))
                            .font(.caption).monitorSecondary()
                    } else {
                        Text(L10n.text("尚未验证当前配置")).font(.caption).monitorSecondary()
                    }
                    Text(L10n.text("导入只填入表单，不执行 .zshrc；点击保存后写入本机钥匙串。已保存配置优先于进程环境变量。验证只查一次；开启后每 5 分钟刷新。"))
                        .font(.caption).monitorSecondary()
                    Text(L10n.text("今日按本机时区统计；余额为账户共享金额，用量为当前 Key 的所有模型，不仅是 Claude。无总额度时不显示百分比，小猫保持睡眠。"))
                        .font(.caption).monitorSecondary()
                    Link(L10n.text("TeamoRouter 用量 API 说明 ↗"), destination: URL(string: "https://api.teamorouter.com/docs/open-api")!)
                        .font(.caption)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).monitorSurface()
        .onAppear { baseDraft = savedBase }
    }

    private func importConfiguration() {
        busy = true
        message = nil
        Task {
            do {
                let config = try await Task.detached { try TeamoConfiguration.importZshrc() }.value
                baseDraft = config.baseURL
                keyDraft = config.token
                message = L10n.text("已导入到表单（密钥已隐藏），请保存后验证。未修改 .zshrc。")
            } catch { message = (error as? TeamoReadError ?? .importUnreadable).localizedDescription }
            busy = false
        }
    }

    private func saveConfiguration() {
        let base = baseDraft
        let key = keyDraft
        busy = true
        message = nil
        Task {
            do {
                let normalizedBase = try await Task.detached {
                    let token = key.isEmpty ? try TeamoKeychain.read(allowInteraction: true).token : key
                    let config = try TeamoConfiguration(baseURL: base, token: token)
                    try TeamoKeychain.save(config)
                    return config.baseURL
                }.value
                savedBase = normalizedBase
                baseDraft = normalizedBase
                keyDraft = ""
                store.teamoCredentialChanged()
                message = L10n.text("已保存到钥匙串，请验证连接。")
            } catch { message = (error as? TeamoReadError ?? .keychain).localizedDescription }
            busy = false
        }
    }
}

struct TeamoQuotaCard: View {
    @ObservedObject var store: ProviderStore
    var detailed = false
    var body: some View {
        let detailed = detailed || store.expandedProviders.contains(.teamo)
        let quota = store.isRefreshingTeamo ? nil : store.teamoSnapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DisclosureButton(title: "TeamoRouter", expanded: detailed) { store.toggleProviderDetails(.teamo) }
                Label("TeamoRouter", systemImage: "arrow.triangle.branch").font(.subheadline.weight(.semibold))
                Spacer()
                if store.isRefreshingTeamo { ProgressView().controlSize(.mini) }
                if let error = store.teamoError {
                    Image(systemName: "exclamationmark.triangle").help(error.localizedDescription)
                        .accessibilityLabel(error.localizedDescription)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("余额")).font(.caption).monitorSecondary()
                Text(quota?.balanceText ?? "—").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer(minLength: 4)
                Text(L10n.text("今日 ") + (quota?.costText ?? "—")).font(.caption).monospacedDigit()
            }.padding(.top, 6)
            DisclosureContent(expanded: detailed) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Claude Code API · 按量计费")).font(.caption).monitorSecondary()
                    if let error = store.teamoError { Text(error.localizedDescription).font(.caption) }
                    LabeledContent(L10n.text("今日已用 Token"), value: quota?.totalTokens.formatted() ?? "—").font(.caption)
                    LabeledContent(L10n.text("今日请求数"), value: quota?.requests.formatted() ?? "—").font(.caption)
                    Text(L10n.text("余额属于账户；今日消费与用量属于当前 Key，包含所有模型。"))
                        .font(.caption2).monitorSecondary()
                    if let quota {
                        Text(L10n.format("统计 %@ – %@ · 本机时区", L10n.date(Date(timeIntervalSince1970: Double(quota.start))), Date(timeIntervalSince1970: Double(quota.end)).formatted(date: .omitted, time: .shortened)))
                            .font(.caption2).monitorSecondary()
                    }
                    Text(L10n.text("最近成功 ") + (store.teamoLastSuccessAt?.formatted(.dateTime.month().day().hour().minute()) ?? "—"))
                        .font(.caption2).monitorSecondary()
                }.padding(.top, 10)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .monitorSurface(successAt: store.teamoLastSuccessAt)
    }
}
