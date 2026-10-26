import AppKit
import SwiftUI

struct MonitorView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var store: ProviderStore
    let onQuit: () -> Void
    let onSettings: () -> Void
    var viewportHeight: CGFloat = 540

    init(model: UsageModel, store: ProviderStore? = nil, onQuit: @escaping () -> Void,
         onSettings: @escaping () -> Void) {
        self.model = model
        self.store = store ?? ProviderStore(codex: model)
        self.onQuit = onQuit
        self.onSettings = onSettings
    }

    var body: some View {
        MonitorPanel(model: model, store: store, onQuit: onQuit, onSettings: onSettings, viewportHeight: viewportHeight)
            .modifier(MonitorThemeScope(appearance: store.appearance, visible: store.popoverVisible))
            .environment(\.locale, store.language.locale)
    }
}

struct MonitorPanel: View {
    @Environment(\.monitorStyle) private var style
    @ObservedObject var model: UsageModel
    @ObservedObject var store: ProviderStore
    let onQuit: () -> Void
    let onSettings: () -> Void
    let viewportHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("额度概览")).font(.headline)
                    Text("Codex Token Monitor").font(.caption).monitorSecondary()
                }
                Spacer()
                Button { store.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .help(L10n.text("刷新已启用的供应商"))
                .accessibilityLabel(L10n.text("刷新所有已启用的额度"))
                .disabled(store.availableMenuSources.isEmpty)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            HStack {
                Text(L10n.text("按服务查看额度")).font(.caption).monitorSecondary()
                Spacer()
                Button { store.toggleAllProviderDetails() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(store.allProviderDetailsExpanded ? -180 : 0))
                            .animation(style.disclosureAnimation(expanded: store.allProviderDetailsExpanded), value: store.allProviderDetailsExpanded)
                            .accessibilityHidden(true)
                        Text(store.allProviderDetailsExpanded ? L10n.text("全部收起") : L10n.text("全部展开"))
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(store.enabledProviders.isEmpty)
            }.padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderSummaryView(model: model, store: store)
                    if store.availableMenuSources.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "switch.2").font(.largeTitle).monitorSecondary()
                            Text(L10n.text("还没有开启监控")).font(.headline)
                            Text(L10n.text("在供应商设置中检查连接条件，\n然后开启你需要的服务。"))
                                .monitorSecondary().multilineTextAlignment(.center)
                            Button(L10n.text("设置供应商"), action: onSettings).buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                }.padding(12)

            }
            .scrollIndicatorsFlash(onAppear: true)
            Divider()
            HStack {
                Button(action: onSettings) { Label(L10n.text("供应商设置"), systemImage: "gearshape") }
                    .buttonStyle(.bordered)
                Spacer()
                Button(action: onQuit) { Label(L10n.text("退出"), systemImage: "power") }
                    .buttonStyle(.borderless).monitorSecondary()
            }.padding(12)
        }
        .frame(width: 360, height: viewportHeight)
        .background { MonitorBackdrop() }
    }

}

struct ProviderDetailView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var store: ProviderStore
    let provider: MonitorProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider == .codex {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text(model.planName)).font(.caption).monitorSecondary()
                    if let error = model.readError { ProviderErrorLabel(error: error) }
                    if model.rateLimitStatus == .manual {
                        Label(L10n.text("手动备选 · 不会回写"), systemImage: "pencil").font(.caption).monitorSecondary()
                    }
                    QuotaMetricRows(metrics: ProviderStore.codexMetrics(model),
                                    loading: model.rateLimitStatus == .loading)
                    updatedAt(model.lastSuccessAt, source: "OpenAI · API")
                    if !model.additionalLimits.isEmpty {
                        DisclosureGroup(L10n.text("附加模型额度")) {
                            ForEach(Array(model.additionalLimits.enumerated()), id: \.offset) { _, limit in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(limit.name).fontWeight(.medium)
                                    Text(limit.summary).monitorSecondary()
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            }
                        }.font(.caption)
                    }
                }
            }
            if provider == .antigravity {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.antigravityError { ProviderErrorLabel(error: error) }
                    if store.antigravityGroups.isEmpty {
                        Text("Gemini / Claude + GPT").font(.subheadline.weight(.medium))
                        QuotaMetricRows(metrics: [], loading: store.isRefreshingAntigravity)
                    } else {
                        ForEach(Array(store.antigravityGroups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Divider() }
                            Text(group.name).font(.subheadline.weight(.semibold))
                            QuotaMetricRows(metrics: group.metrics, loading: store.isRefreshingAntigravity)
                        }
                    }
                    updatedAt(store.antigravityLastSuccessAt, source: "Antigravity · CLI")
                }
            }
            if provider == .claude {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text(store.claudePlanName)).font(.caption).monitorSecondary()
                    if let error = store.claudeError { ProviderErrorLabel(error: error) }
                    QuotaMetricRows(metrics: store.claudeMetrics,
                                    loading: store.isRefreshingClaude)
                    updatedAt(store.claudeLastSuccessAt, source: "Anthropic · OAuth API")
                    if store.claudeError == .rateLimited {
                        Text(L10n.text("下次尝试 ") + L10n.date(store.nextClaudeRefresh))
                            .font(.caption).monitorSecondary()
                    }
                }
            }
            if provider == .warp {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.warpError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    let quota = store.warpSnapshot
                    Text(quota?.balanceText ?? "— Credits").font(.title3.weight(.semibold)).monospacedDigit()
                    if let metric = quota?.metric {
                        QuotaProgressBar(value: metric.remainingPercent,
                                         tint: QuotaLevel(remainingPercent: metric.remainingPercent).color,
                                         status: QuotaLevel(remainingPercent: metric.remainingPercent).title)
                        Text(L10n.text("周期剩余 ") + metric.remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                            .font(.caption).monitorSecondary()
                    }
                    Text(L10n.text("重置 ") + (quota?.resetsAt.map { L10n.date($0) } ?? "—"))
                        .font(.caption).monitorSecondary()
                    LabeledContent(L10n.text("个人额外 Credits"), value: quota?.bonusRemaining?.formatted(.number.precision(.fractionLength(0...1))) ?? "—")
                        .font(.caption)
                    Text(L10n.text("不合并团队额度；无上限或周期额度为 0 时不计算百分比。"))
                        .font(.caption2).monitorSecondary()
                    updatedAt(store.warpLastSuccessAt, source: "Warp · GraphQL")
                }
            }
        }
    }

    private func updatedAt(_ date: Date?, source: String) -> some View {
        HStack {
            Text(source)
            Spacer()
            Text(date.map { L10n.text("成功于 ") + L10n.date($0) } ?? L10n.text("尚未读取成功"))
        }.font(.caption2).monitorSecondary()
    }
}

private struct QuotaMetricRows: View {
    @Environment(\.monitorStyle) private var style
    @Environment(\.locale) private var locale
    let metrics: [QuotaMetric]
    let loading: Bool

    var body: some View {
        VStack(spacing: 12) {
            ForEach(["5h", "weekly"], id: \.self) { window in
                let metric = metrics.first(where: { $0.window == window })
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L10n.text(window == "5h" ? "5 小时" : "每周", locale: locale)).fontWeight(.medium)
                        Spacer()
                        if let metric {
                            Text(metric.remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + L10n.text("% 剩余"))
                                .monospacedDigit().fontWeight(.semibold)
                                .contentTransition(.numericText())
                                .animation(style.animation, value: metric.remainingPercent)
                        } else { Text("—").monitorSecondary() }
                    }.font(.subheadline)
                    if let metric {
                        QuotaProgressBar(value: metric.remainingPercent,
                                         tint: QuotaLevel(remainingPercent: metric.remainingPercent).color,
                                         status: QuotaLevel(remainingPercent: metric.remainingPercent).title)
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(metric.resetsAt.map { L10n.text("重置 ") + L10n.date($0) } ?? L10n.text("未提供重置时间"))
                            if loading { Text(L10n.text("· 更新中")) }
                        }.font(.caption).monitorSecondary()
                    } else {
                        Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6).accessibilityHidden(true)
                        Text(loading ? L10n.text("正在读取…") : L10n.text("未提供此窗口或暂不可用"))
                            .font(.caption).monitorSecondary()
                    }
                }
            }
            ForEach(metrics.filter { $0.window != "5h" && $0.window != "weekly" }) { metric in
                LabeledContent(metric.title, value: metric.remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + L10n.text("% 剩余"))
                    .font(.caption)
            }
        }
    }
}

private struct ProviderErrorLabel: View {
    let error: ProviderReadError
    @Environment(\.locale) private var locale
    var body: some View {
        Label(L10n.text(error.localizedDescription, locale: locale), systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func monitorCard(successAt: Date? = nil) -> some View {
        self.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .monitorSurface(successAt: successAt)
    }
}

enum MonitorSettingsSection: String, CaseIterable, Identifiable {
    case providers = "服务与账号", display = "菜单栏与显示", appearance = "外观", writeBack = "Codex 回写"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .providers: "switch.2"
        case .display: "menubar.rectangle"
        case .appearance: "paintpalette"
        case .writeBack: "arrow.up.doc"
        }
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var store: ProviderStore
    @State private var selection = MonitorSettingsSection.providers
    @State private var pathDraft = ""
    @State private var pathSaved = false
    @State private var codexExpanded = false
    @State private var antigravityExpanded = false

    init(model: UsageModel, store: ProviderStore, initialSection: MonitorSettingsSection = .providers,
         expandedProviders: Set<MonitorProvider> = []) {
        self.model = model
        self.store = store
        _selection = State(initialValue: initialSection)
        _codexExpanded = State(initialValue: expandedProviders.contains(.codex))
        _antigravityExpanded = State(initialValue: expandedProviders.contains(.antigravity))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MONITOR").font(.caption.weight(.semibold)).monitorSecondary().padding(10)
                ForEach(MonitorSettingsSection.allCases) { section in
                    Button { selection = section } label: {
                        Label(L10n.text(section.rawValue), systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 8).fill(.tint).opacity(selection == section ? 0.14 : 0)
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                Spacer()
                Text(L10n.text("本地读取 · 按需开启")).font(.caption).monitorSecondary().padding(10)
            }.padding(8).frame(width: store.language == .english ? 194 : 160).background(Color.primary.opacity(0.035))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text(selection.rawValue)).font(.title2.weight(.semibold))
                    switch selection {
                    case .providers: providerSettings
                    case .display: displaySettings
                    case .appearance: MonitorAppearanceSettings(appearance: store.appearance)
                    case .writeBack: CodexWriteBackPane(model: model)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .background { MonitorBackdrop() }
        .modifier(MonitorThemeScope(appearance: store.appearance))
        .environment(\.locale, store.language.locale)
        .onAppear { pathDraft = store.cliPath; store.detectCLI() }
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("检测安装条件不等于验证登录。新服务由你决定是否开启；关闭后停止查询。"))
                .font(.subheadline).monitorSecondary()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { store.codexEnabled }, set: { store.setCodexEnabled($0) })) {
                    HStack { ProviderLogo(brand: .codex); Text("Codex").font(.headline) }
                }.toggleStyle(.switch)
                SettingsDisclosure(title: L10n.text("连接与设置"), expanded: $codexExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("本机登录凭据 + OpenAI API（客户端内部接口）")).font(.subheadline)
                        Label(FileManager.default.fileExists(atPath: DirectCodexUsageReader.authURL.path) ? L10n.text("已发现凭据文件 · 登录有效性需验证") : L10n.text("未发现凭据文件"),
                              systemImage: "doc.badge.gearshape").font(.caption).monitorSecondary()
                        Text(L10n.text("条件：使用 ChatGPT 账号登录 Codex；API Key 登录不能读取订阅额度。"))
                            .font(.caption).monitorSecondary()
                        if let error = model.readError { ProviderErrorLabel(error: error) }
                        HStack {
                            Text(!store.codexEnabled ? L10n.text("已关闭") : model.rateLimitStatus == .loading ? L10n.text("正在验证…") : model.rateLimitStatus == .live ? L10n.text("验证成功") : L10n.text("等待验证"))
                                .font(.caption).monitorSecondary()
                            Spacer()
                            Button(L10n.text("验证连接")) { model.refresh() }.buttonStyle(.bordered)
                                .disabled(!store.codexEnabled || model.rateLimitStatus == .loading)
                        }
                    }
                }
            }.monitorCard()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { store.antigravityEnabled }, set: { store.setAntigravityEnabled($0) })) {
                    HStack { ProviderLogo(brand: .antigravity); Text("Antigravity").font(.headline) }
                }.toggleStyle(.switch)
                SettingsDisclosure(title: L10n.text("连接与设置"), expanded: $antigravityExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("官方 CLI · agy /usage")).font(.subheadline)
                        Text(L10n.text("条件：agy ≥ 1.1.11，并已在终端运行 agy 完成登录。开启后约每分钟刷新，失败时放缓或等待重新验证。"))
                            .font(.caption).monitorSecondary()
                        LabeledWriteBackField(label: L10n.text("CLI 路径（留空自动检测）"), prompt: "/opt/homebrew/bin/agy", text: $pathDraft)
                            .onChange(of: pathDraft) { _, _ in pathSaved = false }
                        HStack {
                            Button(L10n.text("选择文件…"), action: selectCLI).buttonStyle(.bordered)
                            Button(L10n.text("保存路径")) { store.saveCLIPath(pathDraft); pathSaved = true }.buttonStyle(.bordered)
                            if pathSaved { Label(L10n.text("已保存"), systemImage: "checkmark").font(.caption) }
                            Spacer()
                        }
                        if store.isDetecting { Label(L10n.text("检测安装中…"), systemImage: "magnifyingglass").font(.caption) }
                        else if let installation = store.installation {
                            Text(L10n.format("已找到 agy %@", installation.version)).font(.caption.weight(.medium))
                            Text(installation.path).font(.caption).monitorSecondary().textSelection(.enabled)
                        } else if let error = store.detectionError { ProviderErrorLabel(error: error) }
                        if let error = store.antigravityError { ProviderErrorLabel(error: error) }
                        HStack {
                            if store.isRefreshingAntigravity { ProgressView().controlSize(.small); Text(L10n.text("正在验证…")).font(.caption) }
                            else if let time = store.antigravityLastSuccessAt, store.antigravityError == nil, !store.antigravityGroups.isEmpty {
                                Text(L10n.text("成功于 ") + L10n.date(time)).font(.caption)
                            } else { Text(L10n.text("尚未验证当前连接")).font(.caption).monitorSecondary() }
                            Spacer()
                            Button(L10n.text("重新检测")) { store.detectCLI() }.buttonStyle(.bordered).disabled(store.isDetecting)
                            Button(L10n.text("验证连接")) { store.refreshAntigravity() }.buttonStyle(.borderedProminent)
                                .disabled(store.isRefreshingAntigravity || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) != store.cliPath)
                        }
                        Text(L10n.text("验证只查询一次，不会自动打开开关。无需填写 API Key 或 Bearer。"))
                            .font(.caption).monitorSecondary()
                        Link(L10n.text("官方 CLI 使用说明 ↗"), destination: URL(string: "https://antigravity.google/docs/cli/commands/usage")!)
                            .font(.caption)
                    }
                }
            }.monitorCard()
            ClaudeProviderSettings(store: store)
            TeamoProviderSettings(store: store)
            WarpProviderSettings(store: store)
            Text(L10n.text("支持 Codex、Antigravity、Claude Code、TeamoRouter 和 Warp。检测不会扫描或上传你的对话内容。"))
                .font(.caption).monitorSecondary()
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.text("语言"), systemImage: "globe").font(.headline)
                Picker(L10n.text("界面语言"), selection: Binding(get: { store.language }, set: { store.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Text(L10n.text("立即生效，自动保存。")).font(.caption).monitorSecondary()
            }.monitorCard()
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("菜单栏展示")).font(.headline)
                Picker(L10n.text("显示方式"), selection: Binding(get: { store.menuRotationEnabled }, set: { store.setMenuRotationEnabled($0) })) {
                    Text(L10n.text("固定显示")).tag(false)
                    Text(L10n.text("自动轮播")).tag(true)
                }.pickerStyle(.segmented)
                if store.menuRotationEnabled {
                    HStack(spacing: 8) {
                        ForEach(ProviderStore.rotationPresets, id: \.self) { seconds in
                            Button { store.setMenuRotationInterval(seconds) } label: {
                                HStack(spacing: 4) {
                                    if store.menuRotationInterval == seconds { Image(systemName: "checkmark") }
                                    Text(L10n.format("%d秒", seconds))
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                                .tint(store.menuRotationInterval == seconds ? .accentColor : .secondary)
                                .accessibilityAddTraits(store.menuRotationInterval == seconds ? .isSelected : [])
                        }
                    }
                    Stepper(value: Binding(get: { store.menuRotationInterval }, set: { store.setMenuRotationInterval($0) }), in: 5...60) {
                        Text(L10n.format("每 %d 秒切换", store.menuRotationInterval)).monospacedDigit()
                    }
                    Text(L10n.text("依次展示已开启服务的额度组；只有一组时保持显示。弹窗打开时暂停切换，不影响自动刷新。"))
                        .font(.caption).monitorSecondary()
                }
                if store.availableMenuSources.isEmpty {
                    Text(L10n.text("请先在“服务与账号”中开启一个供应商。")).monitorSecondary()
                } else {
                    Picker(store.menuRotationEnabled ? L10n.text("轮播起始组") : L10n.text("展示额度组"), selection: Binding(get: { store.menuSource }, set: { store.setMenuSource($0) })) {
                        ForEach(store.availableMenuSources) { source in Text(source.title).tag(source) }
                    }.pickerStyle(.menu)
                    Text(L10n.text("每次显示一个额度组的两行数据，不混合不同服务的余额。设置自动保存，轮播不会增加接口请求。"))
                        .font(.caption).monitorSecondary()
                    Text(L10n.format("当前：%@", store.displayedMenuSource.title)).font(.caption.weight(.medium))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.menuLines.first)
                        Text(store.menuLines.second)
                    }.font(.system(.subheadline, design: .monospaced)).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }.monitorCard()
            Label(L10n.text("Touch Bar 跟随菜单栏当前额度组，切换与轮播时同步更新。小猫活跃度取当前组的较低余量，刷新按钮只刷新当前供应商。"), systemImage: "rectangle.bottomthird.inset.filled")
                .font(.subheadline).monitorSecondary()
            Text(L10n.text("菜单栏跟随系统单色；窗口自动适配浅色和深色。所有时间使用系统时区。"))
                .font(.caption).monitorSecondary()
        }
    }

    private func selectCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("选择 agy")
        panel.begin { response in
            if response == .OK, let url = panel.url { pathDraft = url.path }
        }
    }
}

struct ClaudeProviderSettings: View {
    @ObservedObject var store: ProviderStore
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { store.claudeEnabled }, set: { store.setClaudeEnabled($0) })) {
                HStack { ProviderLogo(brand: .claude); Text("Claude Code").font(.headline) }
            }.toggleStyle(.switch)
            SettingsDisclosure(title: L10n.text("连接与设置"), expanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("本机登录凭据 · 直连 Anthropic")).font(.subheadline)
                    Text(L10n.text("条件：先使用 Claude 订阅账号登录 Claude Code，并允许读取登录凭据。通过 TeamoRouter API Key 使用 Claude Code？请改用下方 TeamoRouter 配置，本项仅查询官方订阅额度。其他代理及 Bedrock / Vertex 不支持。"))
                        .font(.caption).monitorSecondary()
                    Label(L10n.text("默认账号：登录钥匙串 / ~/.claude/.credentials.json"), systemImage: "key")
                        .font(.caption).monitorSecondary().textSelection(.enabled)
                    Text(L10n.text("每 5 分钟独立刷新，无需保持 Claude Code 运行。内部额度接口可能变化或限流；登录过期时，请回 Claude Code 登录后重新验证。"))
                        .font(.caption).monitorSecondary()
                    if let error = store.claudeError { ProviderErrorLabel(error: error) }
                    if store.claudeError == .rateLimited {
                        Label(L10n.text("暂停查询至 ") + L10n.date(store.nextClaudeRefresh), systemImage: "clock")
                            .font(.caption).monitorSecondary()
                    }
                    HStack {
                        if store.isRefreshingClaude {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("正在验证…")).font(.caption)
                        } else if let time = store.claudeLastSuccessAt, store.claudeError == nil, !store.claudeMetrics.isEmpty {
                            Text(L10n.text(store.claudePlanName) + L10n.text(" · 成功于 ") + L10n.date(time))
                                .font(.caption)
                        } else {
                            Text(store.claudeEnabled ? L10n.text("等待验证") : L10n.text("已关闭自动监控")).font(.caption).monitorSecondary()
                        }
                        Spacer()
                        Button(L10n.text("验证连接")) { store.refreshClaude(allowInteraction: true) }
                            .buttonStyle(.borderedProminent).disabled(store.isRefreshingClaude)
                            .help(L10n.text("只读查询；必要时弹出钥匙串授权提示。限流冷却期间不会再次请求。"))
                    }
                    Text(L10n.text("验证只查询一次，不会开启自动监控。不复制或上传凭据到第三方，不刷新或改写 Claude Code 的登录令牌。仅支持默认配置目录。"))
                        .font(.caption).monitorSecondary()
                    Link(L10n.text("Claude Code 登录说明 ↗"), destination: URL(string: "https://code.claude.com/docs/en/authentication")!)
                        .font(.caption)
                }
            }
        }.monitorCard()
    }
}

struct WarpProviderSettings: View {
    @ObservedObject var store: ProviderStore
    @State private var keyDraft = ""
    @State private var saveMessage: String?
    @State private var saving = false
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { store.warpEnabled }, set: { store.setWarpEnabled($0) })) {
                HStack { ProviderLogo(brand: .warp); Text("Warp").font(.headline) }
            }.toggleStyle(.switch)
            SettingsDisclosure(title: L10n.text("连接与设置"), expanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("个人 API Key · 直连 Warp · 每 5 分钟刷新")).font(.subheadline)
                    Text(L10n.text("在 Warp Settings → Platform → API Keys 创建个人密钥（不是团队 Agent Key）。仅查询 Credits，不运行 AI 任务。不读取或改写 Warp 的登录会话。"))
                        .font(.caption).monitorSecondary()
                    SecureField(L10n.text("个人 API Key（wk-…；留空保留已保存密钥）"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("Warp 个人 API Key"))
                        .disabled(saving)
                        .onChange(of: keyDraft) { _, _ in saveMessage = nil }
                    HStack {
                        Button(L10n.text("保存密钥")) { saveKey() }.buttonStyle(.bordered).disabled(saving || keyDraft.isEmpty)
                        if saving { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(L10n.text("验证连接")) { store.refreshWarp(allowInteraction: true) }.buttonStyle(.borderedProminent)
                            .disabled(saving || !keyDraft.isEmpty || store.isRefreshingWarp ||
                                      (store.warpError == .rateLimited && Date() < store.nextWarpRefresh))
                    }
                    if let saveMessage { Text(saveMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    if let error = store.warpError {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                    if store.warpError == .rateLimited {
                        Text(L10n.text("暂停至 ") + L10n.date(store.nextWarpRefresh)).font(.caption)
                    }
                    Text(store.isRefreshingWarp ? L10n.text("正在验证…") : store.warpLastSuccessAt.map {
                        L10n.text("最近成功 ") + L10n.date($0)
                    } ?? L10n.text("尚未验证当前密钥"))
                        .font(.caption).monitorSecondary()
                    Text(L10n.text("保存到本机登录钥匙串；输入框不会回显密钥。验证只查一次，不自动开启监控。内部额度接口可能变化；个人额外 Credits 单列，不汇总团队余额。"))
                        .font(.caption).monitorSecondary()
                    Link(L10n.text("如何创建 Warp API Key ↗"), destination: URL(string: "https://docs.warp.dev/agents/cli/oz-cli/api-keys/")!)
                        .font(.caption)
                }
            }
        }.monitorCard()
    }

    private func saveKey() {
        let key = keyDraft
        saving = true
        Task {
            do {
                try await Task.detached { try WarpKeychain.save(key) }.value
                store.warpCredentialChanged()
                keyDraft = ""
                saveMessage = L10n.text("已安全保存，请验证连接。")
            } catch { saveMessage = (error as? WarpReadError ?? .keychain).localizedDescription }
            saving = false
        }
    }
}

private struct CodexWriteBackPane: View {
    @ObservedObject var model: UsageModel
    @Environment(\.locale) private var locale
    @AppStorage("writeBackAPIURL") private var apiURL = ""
    @AppStorage("writeBackBearer") private var bearer = ""
    @AppStorage("writeBackCodexKeyID") private var keyID = ""
    @AppStorage("writeBackIntervalMinutes") private var interval = 1
    @AppStorage("writeBackEnabled") private var enabled = false
    @State private var status: WriteBackStatus?
    @State private var fiveHour = QuotaWindow.defaultFiveHour
    @State private var weekly = QuotaWindow.defaultWeekly

    private var sending: Bool { status == .sending || status == .verifying }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("仅回写 Codex 的实时账户额度。其他供应商不会发送到此接口；关闭 Codex 监控会暂停自动回写。", locale: locale))
                .font(.subheadline).monitorSecondary()
            WriteBackSettingsView(apiURL: $apiURL, bearer: $bearer, codexKeyID: $keyID,
                intervalMinutes: $interval, enabled: $enabled, lastSuccessAt: model.writeBackLastSuccessAt,
                consecutiveFailures: model.writeBackConsecutiveFailures, paused: model.writeBackPaused,
                onSave: save, onVerify: {
                    status = .verifying
                    Task { status = await model.verifyWriteBack(apiURL: apiURL, bearer: bearer, codexKeyID: keyID) }
                })
                .disabled(sending)
            if let status { Text(status.title).font(.subheadline).foregroundStyle(status.color) }
            Button {
                status = .sending
                Task { status = await model.submitWriteBack(apiURL: apiURL, bearer: bearer, codexKeyID: keyID) }
            } label: { Label(L10n.text("立即回写 Codex"), systemImage: "arrow.up.circle") }
                .buttonStyle(.bordered).disabled(sending || !model.monitoringEnabled || model.rateLimitStatus != .live)
            Divider()
            DisclosureGroup(L10n.text("手动备用额度 / Touch Bar 预览")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("手动值会明确标记，不参与回写；下一次自动刷新会覆盖。")).font(.caption).monitorSecondary()
                    EditQuotaView(window: $fiveHour, label: L10n.text("5 小时"))
                    EditQuotaView(window: $weekly, label: L10n.text("每周"))
                    Button(L10n.text("使用手动值")) { model.useManualValues(fiveHour: fiveHour, weekly: weekly) }
                        .buttonStyle(.bordered).disabled(!model.monitoringEnabled)
                }.padding(.top, 12)
            }
        }
    }

    private func save() {
        guard let url = URL(string: apiURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil else {
            status = .failure(L10n.text("请填写有效的 API 地址")); return
        }
        guard !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failure(L10n.text("请填写 Bearer 和 Codex Key ID")); return
        }
        model.saveWriteBackConfiguration()
        status = .saved
    }
}
