import AppKit
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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: MonitorView(model: model, onQuit: { [weak self] in self?.quit() })
        )
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
                self?.model.markCompletedConversationsRead()
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
                self?.model.markCompletedConversationsRead()
            }
        }
        model.onRateLimitsUpdated = { [weak self] in self?.updateStatusTitle() }

        model.refresh()
        updateStatusTitle()
        cancellable = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.refresh()
                self?.updateStatusTitle()
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            model.markCompletedConversationsRead()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
    @Published private(set) var conversationStats = ConversationStats()
    var onRateLimitsUpdated: (() -> Void)?

    func refresh() {
        rateLimitStatus = .loading
        onRateLimitsUpdated?()

        let reader = LocalCodexUsageReader()
        let result = reader.read()
        reportedTokens = result.tokens
        databaseAvailable = result.available
        conversationStats = ConversationStatsReader().read()

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

    func markCompletedConversationsRead() {
        ConversationStatsReader.markCompletedConversationsRead()
        conversationStats = ConversationStatsReader().read()
    }

    func useManualValues(fiveHour: QuotaWindow, weekly: QuotaWindow) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        rateLimitStatus = .manual
        onRateLimitsUpdated?()
    }

    private func apply(_ rateLimits: LiveRateLimits) {
        fiveHour = QuotaWindow.from(rateLimit: rateLimits.primary, name: "5 小时额度")
        weekly = QuotaWindow.from(rateLimit: rateLimits.secondary, name: "每周额度")
        rateLimitStatus = .live
        onRateLimitsUpdated?()
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

    static func from(rateLimit: LiveRateLimitWindow, name: String) -> QuotaWindow {
        QuotaWindow(
            name: name,
            budget: 100,
            used: rateLimit.usedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(rateLimit.resetsAt))
        )
    }

}

struct MonitorView: View {
    @ObservedObject var model: UsageModel
    let onQuit: () -> Void
    @State private var fiveHour: QuotaWindow = .defaultFiveHour
    @State private var weekly: QuotaWindow = .defaultWeekly
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(.tint)
                Text("Codex Token Monitor")
                    .font(.headline)
                Spacer()
                Text("本地")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if editing {
                EditQuotaView(window: $fiveHour, label: "5 小时")
                EditQuotaView(window: $weekly, label: "每周")
                HStack {
                    Button("取消") { editing = false }
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

                Divider()

                ConversationStatsView(stats: model.conversationStats)

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                Text(model.rateLimitStatus.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.rateLimitStatus.detail)
                            .font(.title3.monospacedDigit())
                    }
                    Spacer()
                    Button("手动备选") {
                        fiveHour = model.fiveHour ?? .defaultFiveHour
                        weekly = model.weekly ?? .defaultWeekly
                        editing = true
                    }
                }

                HStack(alignment: .bottom) {
                    Text("直接使用本机 Codex 登录凭据读取 OpenAI 额度；读取失败时显示占位符。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("退出", action: onQuit)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.refresh() }
    }
}

struct ConversationStatsView: View {
    let stats: ConversationStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("对话状态")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if !stats.available {
                    Text("等待本机数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ConversationStatTile(title: "运行中", value: stats.running, systemImage: "bolt.fill", color: .blue)
                ConversationStatTile(title: "未读完成", value: stats.unreadCompleted, systemImage: "envelope.badge.fill", color: .orange)
                ConversationStatTile(title: "需输入", value: stats.needsInput, systemImage: "hand.raised.fill", color: .red)
            }
            Text("“未读完成”按本监控上次关闭面板后新增的完成对话统计；“需输入”为本地状态估算。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct ConversationStatTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(color)
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationStatsReader {
    private static let seenKey = "conversation.completed.lastSeenUpdatedAt"
    private static let initializedKey = "conversation.completed.initialized"

    func read() -> ConversationStats {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stateURL = [
            home.appending(path: ".codex/sqlite/state_5.sqlite"),
            home.appending(path: ".codex/state_5.sqlite")
        ].first(where: { FileManager.default.fileExists(atPath: $0.path()) })
        let historyURL = home.appending(path: ".codex/thread_history_1.sqlite")
        guard let stateURL, FileManager.default.fileExists(atPath: historyURL.path()) else {
            return ConversationStats()
        }

        let threadRows = runSQLite(stateURL, "SELECT id || char(9) || updated_at FROM threads WHERE archived = 0;")
        let activeThreads = Dictionary(uniqueKeysWithValues: threadRows.compactMap { row -> (String, Int64)? in
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let updatedAt = Int64(parts[1]) else { return nil }
            return (parts[0], updatedAt)
        })
        guard !activeThreads.isEmpty else { return ConversationStats(available: true) }

        let latestTurns = runSQLite(historyURL, """
            SELECT thread_id || char(9) || status
            FROM (
                SELECT thread_id, status,
                       ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY rollout_ordinal DESC) AS row_number
                FROM thread_turns
            )
            WHERE row_number = 1;
            """)
        let statuses = Dictionary(uniqueKeysWithValues: latestTurns.compactMap { row -> (String, String)? in
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })

        let latestItems = runSQLite(historyURL, """
            SELECT thread_id || char(9) || item_type || char(9) || item_json
            FROM (
                SELECT thread_id, item_type, item_json,
                       ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY rollout_ordinal DESC) AS row_number
                FROM thread_items
            )
            WHERE row_number = 1;
            """)
        let itemPayloads = Dictionary(uniqueKeysWithValues: latestItems.compactMap { row -> (String, String)? in
            let parts = row.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[1] == "agentMessage" else { return nil }
            return (parts[0], parts[2])
        })

        let runningIDs = activeThreads.keys.filter { statuses[$0] == "inProgress" }
        let needsInputIDs = runningIDs.filter { id in
            guard let payload = itemPayloads[id]?.lowercased() else { return false }
            return payload.contains("request_user_input") ||
                payload.contains("user input") ||
                payload.contains("approval") ||
                payload.contains("confirm") ||
                payload.contains("请提供") ||
                payload.contains("请输入") ||
                payload.contains("请选择") ||
                payload.contains("需要用户")
        }
        let completed = activeThreads.filter { statuses[$0.key] == "completed" }
        let unread = unreadCompletedCount(completed)

        return ConversationStats(
            running: runningIDs.count - needsInputIDs.count,
            unreadCompleted: unread,
            needsInput: needsInputIDs.count,
            available: true
        )
    }

    static func markCompletedConversationsRead() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stateURL = [
            home.appending(path: ".codex/sqlite/state_5.sqlite"),
            home.appending(path: ".codex/state_5.sqlite")
        ].first(where: { FileManager.default.fileExists(atPath: $0.path()) })
        guard let stateURL else { return }
        let rows = runSQLite(stateURL, "SELECT id || char(9) || updated_at FROM threads WHERE archived = 0;")
        var seen = readSeen()
        for row in rows {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let updatedAt = Int64(parts[1]) else { continue }
            seen[parts[0]] = updatedAt
        }
        UserDefaults.standard.set(seen, forKey: seenKey)
    }

    private func unreadCompletedCount(_ completed: [String: Int64]) -> Int {
        let defaults = UserDefaults.standard
        var seen = Self.readSeen()
        if !defaults.bool(forKey: Self.initializedKey) {
            seen = completed
            defaults.set(true, forKey: Self.initializedKey)
            defaults.set(seen, forKey: Self.seenKey)
            return 0
        }
        return completed.reduce(into: 0) { result, entry in
            if entry.value > (seen[entry.key] ?? 0) { result += 1 }
        }
    }

    private static func readSeen() -> [String: Int64] {
        (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: NSNumber])?.reduce(into: [:]) {
            $0[$1.key] = $1.value.int64Value
        } ?? [:]
    }

    private func runSQLite(_ url: URL, _ query: String) -> [String] {
        Self.runSQLite(url, query)
    }

    private static func runSQLite(_ url: URL, _ query: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", "-noheader", "-separator", "\t", url.path(), query]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return [] }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        } catch {
            return []
        }
    }
}

struct QuotaRow: View {
    let window: QuotaWindow

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
                Text(window.remainingText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            QuotaProgressBar(value: window.remainingPercent)
            Label("重置：\(resetText)", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct QuotaProgressBar: View {
    let value: Double

    private var clampedValue: Double {
        min(max(value, 0), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: proxy.size.width * clampedValue / 100)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("剩余额度")
        .accessibilityValue("\(Int(clampedValue.rounded()))%")
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
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
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

struct ConversationStats: Equatable {
    var running = 0
    var unreadCompleted = 0
    var needsInput = 0
    var available = false
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
