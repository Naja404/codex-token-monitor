import AppKit
import SwiftUI

enum ProviderBrand: String, CaseIterable {
    case codex, antigravity, claude, warp
    var title: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .claude: "Claude Code"
        case .warp: "Warp"
        }
    }
    var image: NSImage? {
        Self.resourceBundle(in: .main)?.url(forResource: rawValue, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    static func resourceBundle(in application: Bundle) -> Bundle? {
        // Signed app bundles cannot have loose resources at their root. Never fall
        // back to the developer's build directory when running a distributed app.
        if application.bundleURL.pathExtension == "app" {
            return application.resourceURL.flatMap {
                Bundle(url: $0.appendingPathComponent("CodexTokenMonitor_CodexTokenMonitor.bundle"))
            }
        }
        return .module
    }
}

struct ProviderLogo: View {
    let brand: ProviderBrand
    var body: some View {
        Group {
            if let image = brand.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "square.dashed").resizable().scaledToFit() }
        }.frame(width: 26, height: 26).accessibilityHidden(true)
    }
}

struct ProviderSummaryView: View {
    @Environment(\.monitorStyle) private var style
    @ObservedObject var model: UsageModel
    @ObservedObject var store: ProviderStore

    var body: some View {
        VStack(spacing: 8) {
            if store.teamoEnabled { TeamoQuotaCard(store: store) }
            if store.codexEnabled {
                card(.codex, loading: model.rateLimitStatus == .loading,
                     error: model.readError?.localizedDescription, manual: model.rateLimitStatus == .manual,
                     successAt: model.lastSuccessAt) {
                    metricLine(model.rateLimitStatus == .live || model.rateLimitStatus == .manual ? ProviderStore.codexMetrics(model) : [])
                }
            }
            if store.antigravityEnabled {
                card(.antigravity, loading: store.isRefreshingAntigravity, error: store.antigravityError?.localizedDescription,
                     successAt: store.antigravityLastSuccessAt) {
                    metricLine(store.isRefreshingAntigravity ? [] : store.antigravityGroups.first { $0.id == "gemini" }?.metrics ?? [], label: "Gemini")
                    metricLine(store.isRefreshingAntigravity ? [] : store.antigravityGroups.first { $0.id == "3p" }?.metrics ?? [], label: "Claude + GPT")
                }
            }
            if store.claudeEnabled {
                card(.claude, loading: store.isRefreshingClaude, error: store.claudeError?.localizedDescription,
                     successAt: store.claudeLastSuccessAt) {
                    metricLine(store.isRefreshingClaude ? [] : store.claudeMetrics)
                }
            }
            if store.warpEnabled {
                card(.warp, loading: store.isRefreshingWarp, error: store.warpError?.localizedDescription,
                     successAt: store.warpLastSuccessAt) {
                    let quota = store.isRefreshingWarp ? nil : store.warpSnapshot
                    HStack(alignment: .firstTextBaseline) {
                        Text("周期").font(.caption).monitorSecondary()
                        Text(quota?.balanceText ?? "— Credits")
                            .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText()).animation(style.animation, value: quota?.remaining)
                        Spacer(minLength: 4)
                        if let metric = quota?.metric {
                            Text(metric.remainingPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ brand: ProviderBrand, loading: Bool, error: String?, manual: Bool = false, successAt: Date?,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProviderLogo(brand: brand)
                Text(brand.title).font(.subheadline.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.mini).accessibilityLabel("正在读取") }
                if manual { Text("手动").font(.caption2).monitorSecondary() }
                if let error {
                    Label("连接异常", systemImage: "exclamationmark.triangle")
                        .font(.caption2).monitorSecondary().help(error)
                        .accessibilityLabel(error)
                }
            }
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorSurface(successAt: successAt)
    }

    private func metricLine(_ metrics: [QuotaMetric], label: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let label { Text(label).font(.caption2).monitorSecondary().frame(width: 76, alignment: .leading) }
            ForEach(["5h", "weekly"], id: \.self) { window in
                let metric = metrics.first { $0.window == window }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(window == "5h" ? "5h" : "7d").font(.caption).monitorSecondary()
                    Text(metric.map { $0.remainingPercent.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                        .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: metric == nil ? style.palette.secondary : style.palette.primary))
                        .contentTransition(.numericText()).animation(style.animation, value: metric?.remainingPercent)
                    if let metric {
                        Capsule().fill(QuotaLevel(remainingPercent: metric.remainingPercent).color)
                            .frame(width: 3, height: 13).accessibilityHidden(true)
                    }
                }.frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((window == "5h" ? "5 小时剩余 " : "每周剩余 ") + (metric.map { "\($0.remainingPercent)%" } ?? "未知"))
            }
        }
    }
}
