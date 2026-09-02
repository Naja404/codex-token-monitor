import AppKit
import Foundation
import SwiftUI

@main
struct CodexTokenMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let model = UsageModel()
    private let popover = NSPopover()
    private var cancellable: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        print("Codex Token Monitor 已启动，请查看 macOS 菜单栏。按 Ctrl-C 可退出。")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 304)
        popover.contentViewController = NSHostingController(
            rootView: MonitorView(
                model: model,
                onQuit: { [weak self] in self?.quit() },
                onWriteBackSettingsVisibilityChanged: { [weak self] visible in
                    self?.popover.contentSize = NSSize(width: 300, height: visible ? 600 : 304)
                }
            )
        )
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
        model.onRateLimitsUpdated = { [weak self] in self?.updateStatusTitle() }

        model.refresh()
        model.performScheduledWriteBack()
        updateStatusTitle()
        cancellable = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.refresh()
                self?.model.performScheduledWriteBack()
                self?.updateStatusTitle()
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        // On a secondary display, AppKit passes the status-bar button that was
        // actually clicked. Using statusItem.button can still refer to another display.
        guard let button = (sender as? NSStatusBarButton) ?? statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            positionPopoverOnClickedScreen(anchorButton: button)
        }
    }

    private func positionPopoverOnClickedScreen(anchorButton: NSStatusBarButton) {
        let clickLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(clickLocation) }) else { return }

        // NSPopover can initially use the primary-display coordinates when the
        // first click happens in another display's menu bar. Move its window
        // after AppKit creates it, using the real global mouse location instead.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.popover.contentViewController?.view.window else { return }

            let margin: CGFloat = 8
            let visibleFrame = screen.visibleFrame
            let anchorRect = anchorButton.convert(anchorButton.bounds, to: nil)
            let anchorFrame = anchorButton.window?.convertToScreen(anchorRect)
            let arrowOffset = anchorFrame.map { $0.midX - window.frame.minX }
            let preferredOffset = arrowOffset.flatMap { (0...window.frame.width).contains($0) ? $0 : nil }
            let originX = min(
                max(clickLocation.x - (preferredOffset ?? window.frame.width / 2), visibleFrame.minX + margin),
                visibleFrame.maxX - window.frame.width - margin
            )
            let originY = visibleFrame.maxY - window.frame.height
            window.setFrameOrigin(NSPoint(x: originX, y: originY))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusTitle() {
        let fiveHour = model.fiveHour.map {
            "5小时 \(Int($0.remainingPercent.rounded()))% · \($0.resetsAt.formatted(date: .omitted, time: .shortened))"
        } ?? "5小时 — · —"
        let weekly = model.weekly.map {
            "一周 \(Int($0.remainingPercent.rounded()))% · \($0.resetsAt.formatted(.dateTime.month().day()))"
        } ?? "一周 — · —"
        statusItem?.button?.title = ""
        statusItem?.button?.image = MenuBarUsageImage.make(firstLine: fiveHour, secondLine: weekly)
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = "\(fiveHour)；\(weekly)"
    }
}

enum MenuBarUsageImage {
    static func make(firstLine: String, secondLine: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let widestLine = max(
            (firstLine as NSString).size(withAttributes: attributes).width,
            (secondLine as NSString).size(withAttributes: attributes).width
        )
        let image = NSImage(size: NSSize(width: ceil(widestLine) + 6, height: 22))
        image.lockFocus()
        // Explicit coordinates leave safe top/bottom padding; AppKit's multiline baseline can clip the first line.
        firstLine.draw(at: NSPoint(x: 3, y: 10), withAttributes: attributes)
        secondLine.draw(at: NSPoint(x: 3, y: 1), withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var fiveHour: QuotaWindow?
    @Published private(set) var weekly: QuotaWindow?
    @Published private(set) var reportedTokens = 0
    @Published private(set) var databaseAvailable = false
    @Published private(set) var rateLimitStatus: RateLimitStatus = .loading
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var writeBackLastSuccessAt: Date?
    @Published private(set) var writeBackConsecutiveFailures = 0
    @Published private(set) var writeBackPaused = false
    var onRateLimitsUpdated: (() -> Void)?
    private var writeBackTaskInFlight = false

    init() {
        let defaults = UserDefaults.standard
        let lastSuccess = defaults.double(forKey: "writeBackLastSuccessAt")
        writeBackLastSuccessAt = lastSuccess > 0 ? Date(timeIntervalSince1970: lastSuccess) : nil
        writeBackConsecutiveFailures = defaults.integer(forKey: "writeBackConsecutiveFailures")
        writeBackPaused = defaults.bool(forKey: "writeBackPaused")
    }

    func refresh() {
        lastRefreshAt = .now
        rateLimitStatus = .loading
        onRateLimitsUpdated?()

        let reader = LocalCodexUsageReader()
        let result = reader.read()
        reportedTokens = result.tokens
        databaseAvailable = result.available

        Task { [weak self] in
            let rateLimits = await DirectCodexUsageReader().read()
            guard let self else { return }
            guard let rateLimits else {
                self.rateLimitStatus = .unavailable
                self.onRateLimitsUpdated?()
                return
            }
            self.apply(rateLimits)
        }
    }

    func useManualValues(fiveHour: QuotaWindow, weekly: QuotaWindow) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        rateLimitStatus = .manual
        onRateLimitsUpdated?()
    }

    func saveWriteBackConfiguration() {
        writeBackConsecutiveFailures = 0
        writeBackPaused = false
        UserDefaults.standard.set(0, forKey: "writeBackConsecutiveFailures")
        UserDefaults.standard.set(false, forKey: "writeBackPaused")
    }

    func performScheduledWriteBack() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "writeBackEnabled"), !writeBackPaused,
              !writeBackTaskInFlight else { return }
        let interval = max(1, defaults.integer(forKey: "writeBackIntervalMinutes"))
        let lastAttempt = defaults.double(forKey: "writeBackLastAttemptAt")
        guard lastAttempt == 0 || Date().timeIntervalSince1970 - lastAttempt >= Double(interval * 60) else {
            return
        }
        let apiURL = defaults.string(forKey: "writeBackAPIURL") ?? ""
        let bearer = defaults.string(forKey: "writeBackBearer") ?? ""
        let codexKeyID = defaults.string(forKey: "writeBackCodexKeyID") ?? ""
        guard !apiURL.isEmpty, !bearer.isEmpty, !codexKeyID.isEmpty else { return }

        defaults.set(Date().timeIntervalSince1970, forKey: "writeBackLastAttemptAt")
        writeBackTaskInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.writeBack(apiURL: apiURL, bearer: bearer, codexKeyID: codexKeyID)
            self.recordWriteBackResult(result)
            self.writeBackTaskInFlight = false
        }
    }

    func submitWriteBack(apiURL: String, bearer: String, codexKeyID: String) async -> WriteBackStatus {
        let result = await writeBack(apiURL: apiURL, bearer: bearer, codexKeyID: codexKeyID)
        recordWriteBackResult(result)
        return result
    }

    func verifyWriteBack(apiURL: String, bearer: String, codexKeyID: String) async -> WriteBackStatus {
        let result = await writeBack(apiURL: apiURL, bearer: bearer, codexKeyID: codexKeyID)
        if case .success = result { return .verified }
        return result
    }

    func writeBack(apiURL: String, bearer: String, codexKeyID: String) async -> WriteBackStatus {
        let trimmedURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBearer = bearer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKeyID = codexKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "https" || url.scheme == "http" else {
            return .failure("请填写有效的 API 地址")
        }
        guard !trimmedBearer.isEmpty else { return .failure("请填写 Bearer") }
        guard !trimmedKeyID.isEmpty else { return .failure("请填写 Codex Key ID") }
        guard let fiveHour, let weekly else {
            return .failure("额度尚未读取完成，请稍后重试")
        }

        let payload = WriteBackPayload(
            codexKeyID: trimmedKeyID,
            fiveHour: .init(
                remainingPercent: Int(fiveHour.remainingPercent.rounded()),
                resetTime: Self.timeFormatter.string(from: fiveHour.resetsAt)
            ),
            sevenDay: .init(
                remainingPercent: Int(weekly.remainingPercent.rounded()),
                resetDate: Self.dateFormatter.string(from: weekly.resetsAt)
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedBearer.hasPrefix("Bearer ") ? trimmedBearer : "Bearer \(trimmedBearer)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("API 返回无效响应")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return .failure("API 返回 HTTP \(httpResponse.statusCode)")
            }
            return .success
        } catch {
            return .failure("回写失败：\(error.localizedDescription)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private func apply(_ rateLimits: LiveRateLimits) {
        fiveHour = QuotaWindow.from(rateLimit: rateLimits.primary, name: "5 小时额度")
        weekly = QuotaWindow.from(rateLimit: rateLimits.secondary, name: "每周额度")
        rateLimitStatus = .live
        onRateLimitsUpdated?()
    }

    private func recordWriteBackResult(_ result: WriteBackStatus) {
        let defaults = UserDefaults.standard
        switch result {
        case .success:
            writeBackLastSuccessAt = .now
            writeBackConsecutiveFailures = 0
            writeBackPaused = false
            defaults.set(writeBackLastSuccessAt?.timeIntervalSince1970, forKey: "writeBackLastSuccessAt")
            defaults.set(0, forKey: "writeBackConsecutiveFailures")
            defaults.set(false, forKey: "writeBackPaused")
        case .failure:
            writeBackConsecutiveFailures += 1
            if writeBackConsecutiveFailures >= 10 {
                writeBackPaused = true
            }
            defaults.set(writeBackConsecutiveFailures, forKey: "writeBackConsecutiveFailures")
            defaults.set(writeBackPaused, forKey: "writeBackPaused")
        case .sending, .verifying, .saved, .verified:
            break
        }
    }
}

enum WriteBackStatus: Equatable {
    case sending
    case verifying
    case saved
    case verified
    case success
    case failure(String)

    var title: String {
        switch self {
        case .sending: "正在回写…"
        case .verifying: "正在验证…"
        case .saved: "配置已保存"
        case .verified: "连接验证成功"
        case .success: "回写成功"
        case .failure(let message): message
        }
    }

    var color: Color {
        switch self {
        case .sending, .verifying: .secondary
        case .saved, .verified, .success: .green
        case .failure: .red
        }
    }
}

private struct WriteBackPayload: Encodable {
    let codexKeyID: String
    let fiveHour: Window
    let sevenDay: Window

    enum CodingKeys: String, CodingKey {
        case codexKeyID = "codex_key_id"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Encodable {
        let remainingPercent: Int
        let resetTime: String?
        let resetDate: String?

        enum CodingKeys: String, CodingKey {
            case remainingPercent = "remaining_percent"
            case resetTime = "reset_time"
            case resetDate = "reset_date"
        }

        init(remainingPercent: Int, resetTime: String) {
            self.remainingPercent = remainingPercent
            self.resetTime = resetTime
            self.resetDate = nil
        }

        init(remainingPercent: Int, resetDate: String) {
            self.remainingPercent = remainingPercent
            self.resetTime = nil
            self.resetDate = resetDate
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(remainingPercent, forKey: .remainingPercent)
            if let resetTime { try container.encode(resetTime, forKey: .resetTime) }
            if let resetDate { try container.encode(resetDate, forKey: .resetDate) }
        }
    }
}

enum RateLimitStatus {
    case loading
    case live
    case unavailable
    case manual

    var title: String {
        switch self {
        case .loading: "正在读取 Codex 实时额度…"
        case .live: "当前账户的实时额度"
        case .unavailable: "未读取到 Codex 实时额度"
        case .manual: "手动填写的备用额度"
        }
    }

    var detail: String {
        switch self {
        case .loading: "—"
        case .live: "已直连 OpenAI"
        case .unavailable: "请先在本机登录 Codex"
        case .manual: "不会伪装为实时数据"
        }
    }
}

struct QuotaWindow: Codable, Equatable {
    var name: String
    var budget: Int
    var used: Int
    var resetsAt: Date

    static let defaultFiveHour = QuotaWindow(
        name: "5 小时额度",
        budget: 100,
        used: 38,
        resetsAt: Calendar.current.date(byAdding: .hour, value: 3, to: .now)!
    )
    static let defaultWeekly = QuotaWindow(
        name: "每周额度",
        budget: 100,
        used: 22,
        resetsAt: Calendar.current.date(byAdding: .day, value: 4, to: .now)!
    )

    var remainingPercent: Double {
        guard budget > 0 else { return 0 }
        return max(0, min(100, Double(budget - used) / Double(budget) * 100))
    }

    var remainingText: String { "\(Int(remainingPercent.rounded()))% 剩余" }

    var level: QuotaLevel {
        QuotaLevel(remainingPercent: remainingPercent)
    }

    static func from(rateLimit: LiveRateLimitWindow, name: String) -> QuotaWindow {
        QuotaWindow(
            name: name,
            budget: 100,
            used: rateLimit.usedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(rateLimit.resetsAt))
        )
    }

}

enum QuotaLevel {
    case sufficient
    case attention
    case low
    case critical

    init(remainingPercent: Double) {
        switch remainingPercent {
        case 80...: self = .sufficient
        case 50..<80: self = .attention
        case 20..<50: self = .low
        default: self = .critical
        }
    }

    var title: String {
        switch self {
        case .sufficient: "充足"
        case .attention: "注意"
        case .low: "偏低"
        case .critical: "紧急"
        }
    }

    var color: Color {
        switch self {
        case .sufficient: .green.opacity(0.72)
        case .attention: .orange.opacity(0.72)
        case .low: .yellow.opacity(0.76)
        case .critical: .red.opacity(0.68)
        }
    }

    var badgeBackground: Color { color.opacity(0.14) }

    var symbol: String {
        switch self {
        case .sufficient: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .low: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

struct MonitorView: View {
    @ObservedObject var model: UsageModel
    let onQuit: () -> Void
    let onWriteBackSettingsVisibilityChanged: (Bool) -> Void
    @State private var fiveHour: QuotaWindow = .defaultFiveHour
    @State private var weekly: QuotaWindow = .defaultWeekly
    @State private var editing = false
    @State private var showWriteBackSettings = false
    @AppStorage("writeBackAPIURL") private var writeBackAPIURL = ""
    @AppStorage("writeBackBearer") private var writeBackBearer = ""
    @AppStorage("writeBackCodexKeyID") private var writeBackCodexKeyID = ""
    @AppStorage("writeBackIntervalMinutes") private var writeBackIntervalMinutes = 1
    @AppStorage("writeBackEnabled") private var writeBackEnabled = false
    @State private var writeBackStatus: WriteBackStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(.tint)
                Text("Codex Token Monitor")
                    .font(.headline)
                Spacer()
                Text(model.lastRefreshAt?.formatted(date: .omitted, time: .shortened) ?? "未刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("立即刷新")
                .accessibilityLabel("立即刷新额度")
            }

            if editing {
                EditQuotaView(window: $fiveHour, label: "5 小时")
                EditQuotaView(window: $weekly, label: "每周")
                HStack {
                    Button("取消") { editing = false }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("保存") {
                        model.useManualValues(fiveHour: fiveHour, weekly: weekly)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                if let fiveHour = model.fiveHour {
                    QuotaRow(window: fiveHour)
                } else {
                    QuotaPlaceholderRow(label: "5 小时额度")
                }
                if let weekly = model.weekly {
                    QuotaRow(window: weekly)
                } else {
                    QuotaPlaceholderRow(label: "每周额度")
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                Text(model.rateLimitStatus.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.rateLimitStatus.detail)
                            .font(.title3.monospacedDigit())
                    }
                    Spacer()
                    Button {
                        fiveHour = model.fiveHour ?? .defaultFiveHour
                        weekly = model.weekly ?? .defaultWeekly
                        editing = true
                    } label: {
                        Label("手动备选", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Button {
                        showWriteBackSettings.toggle()
                        writeBackStatus = nil
                        onWriteBackSettingsVisibilityChanged(showWriteBackSettings)
                    } label: {
                        Label(showWriteBackSettings ? "收起设置" : "回写设置", systemImage: showWriteBackSettings ? "chevron.up" : "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button {
                        writeBackStatus = .sending
                        Task { @MainActor in
                            writeBackStatus = await model.submitWriteBack(
                                apiURL: writeBackAPIURL,
                                bearer: writeBackBearer,
                                codexKeyID: writeBackCodexKeyID
                            )
                        }
                    } label: {
                        Label("立即回写", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(writeBackStatus == .sending)
                }

                if showWriteBackSettings {
                    WriteBackSettingsView(
                        apiURL: $writeBackAPIURL,
                        bearer: $writeBackBearer,
                        codexKeyID: $writeBackCodexKeyID,
                        intervalMinutes: $writeBackIntervalMinutes,
                        enabled: $writeBackEnabled,
                        lastSuccessAt: model.writeBackLastSuccessAt,
                        consecutiveFailures: model.writeBackConsecutiveFailures,
                        paused: model.writeBackPaused,
                        onSave: {
                            let trimmedURL = writeBackAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedBearer = writeBackBearer.trimmingCharacters(in: .whitespacesAndNewlines)
                            let trimmedKeyID = writeBackCodexKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let url = URL(string: trimmedURL), url.scheme == "https" || url.scheme == "http" else {
                                writeBackStatus = .failure("请填写有效的 API 地址")
                                return
                            }
                            guard !trimmedBearer.isEmpty else {
                                writeBackStatus = .failure("请填写 Bearer")
                                return
                            }
                            guard !trimmedKeyID.isEmpty else {
                                writeBackStatus = .failure("请填写 Codex Key ID")
                                return
                            }
                            model.saveWriteBackConfiguration()
                            writeBackStatus = .saved
                        },
                        onVerify: {
                            writeBackStatus = .verifying
                            Task { @MainActor in
                                writeBackStatus = await model.verifyWriteBack(
                                    apiURL: writeBackAPIURL,
                                    bearer: writeBackBearer,
                                    codexKeyID: writeBackCodexKeyID
                                )
                            }
                        }
                    )
                }
                if let writeBackStatus {
                    Text(writeBackStatus.title)
                        .font(.caption)
                        .foregroundStyle(writeBackStatus.color)
                }

                HStack(alignment: .bottom) {
                    Text("直接使用本机 Codex 登录凭据读取 OpenAI 额度；读取失败时显示占位符。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("退出", action: onQuit)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial)
        .onAppear { model.refresh() }
    }
}

struct WriteBackSettingsView: View {
    @Binding var apiURL: String
    @Binding var bearer: String
    @Binding var codexKeyID: String
    @Binding var intervalMinutes: Int
    @Binding var enabled: Bool
    let lastSuccessAt: Date?
    let consecutiveFailures: Int
    let paused: Bool
    let onSave: () -> Void
    let onVerify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("回写 Token 余量", systemImage: "arrow.up.doc")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            HStack {
                Text("自动回写")
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .disabled(paused)
                    .accessibilityLabel("自动回写")
            }
            HStack {
                Text("回写间隔")
                Spacer()
                Stepper(value: $intervalMinutes, in: 1...60) {
                    Text("每 \(intervalMinutes) 分钟")
                        .monospacedDigit()
                }
                .fixedSize()
            }
            LabeledWriteBackField(label: "API 地址", prompt: "https://example.com/api/usage", text: $apiURL)
            LabeledWriteBackField(label: "Bearer", prompt: "不含或包含 Bearer 前缀均可", text: $bearer, secure: true)
            LabeledWriteBackField(label: "Codex Key ID", prompt: "codex-…", text: $codexKeyID)
            HStack(spacing: 8) {
                Button(action: onSave) {
                    Label("保存配置", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onVerify) {
                    Label("验证连接", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Text("验证会发送一次当前额度，不会计入失败次数。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("最近成功回写")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lastSuccessAt?.formatted(date: .omitted, time: .shortened) ?? "暂无记录")
                    .monospacedDigit()
            }
            if paused {
                Label("连续失败 \(consecutiveFailures) 次，自动回写已暂停。请修正配置后保存。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if consecutiveFailures > 0 {
                Text("最近连续失败 \(consecutiveFailures) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .glassCard()
    }
}

struct LabeledWriteBackField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

extension View {
    func glassCard(tint: Color = .accentColor) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .background(shape.fill(Color.primary.opacity(0.045)))
            .overlay(shape.fill(tint.opacity(0.065)).allowsHitTesting(false))
            .overlay(shape.stroke(Color.white.opacity(0.30), lineWidth: 0.8).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

struct QuotaRow: View {
    let window: QuotaWindow

    private var level: QuotaLevel { window.level }

    private var resetText: String {
        if window.name == "每周额度" {
            return window.resetsAt.formatted(.dateTime.month().day().hour().minute())
        }
        return window.resetsAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Image(systemName: level.symbol)
                            .foregroundStyle(level.color)
                        Text(level.title)
                    }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(level.badgeBackground, in: Capsule())
                        .foregroundStyle(.primary.opacity(0.76))
                    Text(window.remainingText)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            QuotaProgressBar(
                value: window.remainingPercent,
                tint: level.color,
                status: level.title
            )
            Label("重置：\(resetText)", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard(tint: level.color)
        .animation(.easeOut(duration: 0.2), value: window.remainingPercent)
    }
}

struct QuotaProgressBar: View {
    let value: Double
    let tint: Color
    let status: String

    private var clampedValue: Double {
        min(max(value, 0), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clampedValue / 100)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("剩余额度")
        .accessibilityValue("\(Int(clampedValue.rounded()))%，\(status)")
    }
}

struct QuotaPlaceholderRow: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("—")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView()
                .controlSize(.small)
            Text("等待 Codex 返回实时额度")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard(tint: .secondary)
    }
}

struct EditQuotaView: View {
    @Binding var window: QuotaWindow
    let label: String

    var body: some View {
        GroupBox(label) {
            Grid(alignment: .leading, verticalSpacing: 7) {
                GridRow {
                    Text("总额度")
                    TextField("100", value: $window.budget, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("已使用")
                    TextField("0", value: $window.used, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("重置时间")
                    DatePicker("", selection: $window.resetsAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
        }
    }
}

struct LocalCodexUsageReader {
    func read() -> (tokens: Int, available: Bool) {
        let fileManager = FileManager.default
        let paths = [
            fileManager.homeDirectoryForCurrentUser.appending(path: ".codex/sqlite/state_5.sqlite"),
            fileManager.homeDirectoryForCurrentUser.appending(path: ".codex/state_5.sqlite")
        ]
        guard let path = paths.first(where: { fileManager.fileExists(atPath: $0.path()) }) else {
            return (0, false)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", path.path(), "SELECT COALESCE(SUM(tokens_used), 0) FROM threads;"]
        let output = Pipe()
        task.standardOutput = output

        do {
            try task.run()
            task.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, task.terminationStatus == 0)
        } catch {
            return (0, false)
        }
    }
}

struct LiveRateLimitWindow: Sendable {
    let usedPercent: Int
    let resetsAt: Int64
}

struct LiveRateLimits: Sendable {
    let primary: LiveRateLimitWindow
    let secondary: LiveRateLimitWindow
}

struct DirectCodexUsageReader {
    func read() async -> LiveRateLimits? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
              !auth.tokens.accessToken.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)
            guard let primary = payload.rateLimit.primaryWindow?.asLiveWindow,
                  let secondary = payload.rateLimit.secondaryWindow?.asLiveWindow else { return nil }
            return LiveRateLimits(primary: primary, secondary: secondary)
        } catch {
            return nil
        }
    }
}

private struct CodexAuth: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

private struct CodexWhamUsage: Decodable {
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int64
        let resetAt: Int64

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }

        var asLiveWindow: LiveRateLimitWindow? {
            guard limitWindowSeconds > 0, resetAt > 0 else { return nil }
            return LiveRateLimitWindow(
                usedPercent: max(0, min(100, Int(usedPercent.rounded()))),
                resetsAt: resetAt
            )
        }
    }
}
