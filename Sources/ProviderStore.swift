import Combine
import Foundation

enum MenuQuotaSource: String, CaseIterable, Identifiable {
    case codex, antigravityGemini, antigravityThirdParty, claude, warp, teamo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .antigravityGemini: "Antigravity · Gemini"
        case .antigravityThirdParty: "Antigravity · Claude + GPT"
        case .claude: "Claude Code"
        case .warp: "Warp"
        case .teamo: "TeamoRouter"
        }
    }
}

enum PopoverMode: String, CaseIterable { case summary = "简介", details = "明细" }

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var teamoEnabled: Bool
    @Published private(set) var teamoSnapshot: TeamoUsageSnapshot?
    @Published private(set) var teamoError: TeamoReadError?
    @Published private(set) var isRefreshingTeamo = false
    @Published private(set) var teamoLastSuccessAt: Date?
    @Published private(set) var nextTeamoRefresh = Date.distantPast
    private var teamoTask: Task<Void, Never>?
    private var teamoGeneration = 0
    private var teamoFailures = 0
    private let readTeamo: @Sendable (Bool) async throws -> TeamoUsageSnapshot
    let appearance: MonitorAppearance
    @Published private(set) var popoverVisible = false
    @Published var popoverMode: PopoverMode = .summary
    @Published private(set) var warpEnabled: Bool
    @Published private(set) var warpSnapshot: WarpUsageSnapshot?
    @Published private(set) var warpError: WarpReadError?
    @Published private(set) var isRefreshingWarp = false
    @Published private(set) var warpLastSuccessAt: Date?
    @Published private(set) var nextWarpRefresh = Date.distantPast
    private var warpTask: Task<Void, Never>?
    private var warpGeneration = 0
    private var warpFailures = 0
    private let readWarp: @Sendable (Bool) async throws -> WarpUsageSnapshot
    let codex: UsageModel
    @Published private(set) var codexEnabled: Bool
    @Published private(set) var antigravityEnabled: Bool
    @Published private(set) var claudeEnabled: Bool
    @Published private(set) var claudeMetrics: [QuotaMetric] = []
    @Published private(set) var claudePlanName = "当前登录账号"
    @Published private(set) var claudeError: ProviderReadError?
    @Published private(set) var isRefreshingClaude = false
    @Published private(set) var claudeLastSuccessAt: Date?
    @Published private(set) var claudeLastAttemptAt: Date?
    @Published private(set) var nextClaudeRefresh = Date.distantPast
    private var claudeTask: Task<Void, Never>?
    private var claudeGeneration = 0
    private var claudeFailures = 0
    private let readClaude: @Sendable (Bool) async throws -> ClaudeUsageSnapshot
    @Published private(set) var menuSource: MenuQuotaSource
    @Published private(set) var displayedMenuSource: MenuQuotaSource
    @Published private(set) var menuRotationEnabled: Bool
    @Published private(set) var menuRotationInterval: Int
    private var lastMenuRotation = ProcessInfo.processInfo.systemUptime
    @Published private(set) var cliPath: String
    @Published private(set) var installation: CLIInstallation?
    @Published private(set) var detectionError: ProviderReadError?
    @Published private(set) var isDetecting = false
    @Published private(set) var antigravityGroups: [QuotaGroup] = []
    @Published private(set) var antigravityError: ProviderReadError?
    @Published private(set) var isRefreshingAntigravity = false
    @Published private(set) var antigravityLastSuccessAt: Date?
    @Published private(set) var antigravityLastAttemptAt: Date?
    private(set) var nextAntigravityRefresh = Date.distantPast
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let readAntigravity: @Sendable (String) async throws -> AntigravitySnapshot
    private var refreshTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var generation = 0
    private var detectionGeneration = 0
    private var failures = 0

    init(codex: UsageModel, defaults: UserDefaults = .standard,
         readAntigravity: @escaping @Sendable (String) async throws -> AntigravitySnapshot = {
             try await AntigravityReader().read(pathOverride: $0)
         }, readClaude: @escaping @Sendable (Bool) async throws -> ClaudeUsageSnapshot = {
             try await DirectClaudeUsageReader().read(allowInteraction: $0)
         }, readWarp: @escaping @Sendable (Bool) async throws -> WarpUsageSnapshot = {
             try await WarpUsageReader().read(allowInteraction: $0)
         }, readTeamo: @escaping @Sendable (Bool) async throws -> TeamoUsageSnapshot = {
             try await TeamoUsageReader().read(allowInteraction: $0)
         }) {
        self.codex = codex
        self.defaults = defaults
        appearance = MonitorAppearance(defaults: defaults)
        self.readAntigravity = readAntigravity
        self.readClaude = readClaude
        self.readWarp = readWarp
        self.readTeamo = readTeamo
        teamoEnabled = defaults.bool(forKey: "teamoEnabled")
        warpEnabled = defaults.bool(forKey: "warpEnabled")
        codexEnabled = codex.monitoringEnabled
        antigravityEnabled = defaults.bool(forKey: "antigravityEnabled")
        claudeEnabled = defaults.bool(forKey: "claudeEnabled")
        cliPath = defaults.string(forKey: "antigravityCLIPath") ?? ""
        let savedSource = MenuQuotaSource(rawValue: defaults.string(forKey: "quotaMenuSource") ?? "") ?? .codex
        menuSource = savedSource
        displayedMenuSource = savedSource
        menuRotationEnabled = defaults.bool(forKey: "quotaMenuRotationEnabled")
        menuRotationInterval = min(60, max(5, defaults.object(forKey: "quotaMenuRotationInterval") as? Int ?? 10))
        normalizeMenuSource()
    }

    var availableMenuSources: [MenuQuotaSource] {
        MenuQuotaSource.allCases.filter {
            switch $0 {
            case .codex: codexEnabled
            case .claude: claudeEnabled
            case .warp: warpEnabled
            case .teamo: teamoEnabled
            case .antigravityGemini, .antigravityThirdParty: antigravityEnabled
            }
        }
    }

    func beginPopover() { popoverMode = .summary; popoverVisible = true }
    func endPopover() { popoverVisible = false }

    func setTeamoEnabled(_ enabled: Bool) {
        guard teamoEnabled != enabled else { return }
        let coolingDown = teamoError == .rateLimited && Date() < nextTeamoRefresh
        teamoEnabled = enabled
        defaults.set(enabled, forKey: "teamoEnabled")
        cancelTeamo()
        teamoSnapshot = nil
        teamoLastSuccessAt = nil
        teamoError = coolingDown ? .rateLimited : nil
        if !coolingDown { teamoFailures = 0 }
        normalizeMenuSource()
        onChange?()
        if enabled { refreshTeamo() }
    }

    func teamoCredentialChanged() {
        cancelTeamo()
        teamoSnapshot = nil
        teamoLastSuccessAt = nil
        if teamoError != .rateLimited { teamoError = nil; nextTeamoRefresh = .distantPast }
        onChange?()
    }

    func refreshTeamo(allowInteraction: Bool = false) {
        guard teamoTask == nil, teamoError != .rateLimited || Date() >= nextTeamoRefresh else { return }
        let id = teamoGeneration
        let read = readTeamo
        isRefreshingTeamo = true
        teamoError = nil
        onChange?()
        teamoTask = Task { [weak self] in
            do {
                let result = try await read(allowInteraction)
                guard let self, id == self.teamoGeneration, !Task.isCancelled else { return }
                self.teamoSnapshot = result
                self.teamoLastSuccessAt = .now
                self.teamoFailures = 0
                self.nextTeamoRefresh = Date().addingTimeInterval(300)
            } catch {
                guard let self, id == self.teamoGeneration, !Task.isCancelled else { return }
                self.teamoSnapshot = nil
                let failure = error as? TeamoUsageFailure
                self.teamoError = failure?.reason ?? error as? TeamoReadError ?? .network
                self.teamoFailures += 1
                let backoff = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(min(self.teamoFailures, 4)))))
                self.nextTeamoRefresh = max(backoff, failure?.retryAt ?? .distantPast)
            }
            guard let self, id == self.teamoGeneration else { return }
            self.isRefreshingTeamo = false
            self.teamoTask = nil
            self.onChange?()
        }
    }

    private func cancelTeamo() {
        teamoGeneration += 1
        teamoTask?.cancel()
        teamoTask = nil
        isRefreshingTeamo = false
    }

    func setWarpEnabled(_ enabled: Bool) {
        guard warpEnabled != enabled else { return }
        let coolingDown = warpError == .rateLimited && Date() < nextWarpRefresh
        warpEnabled = enabled
        defaults.set(enabled, forKey: "warpEnabled")
        cancelWarp()
        warpSnapshot = nil
        warpLastSuccessAt = nil
        warpError = coolingDown ? .rateLimited : nil
        if !coolingDown { warpFailures = 0 }
        normalizeMenuSource()
        onChange?()
        if enabled { refreshWarp() }
    }

    func warpCredentialChanged() {
        cancelWarp()
        warpSnapshot = nil
        warpLastSuccessAt = nil
        // Changing a key must not bypass a server rate-limit cooldown.
        if warpError != .rateLimited { warpError = nil; nextWarpRefresh = .distantPast }
        onChange?()
    }

    func refreshWarp(allowInteraction: Bool = false) {
        guard warpTask == nil, warpError != .rateLimited || Date() >= nextWarpRefresh else { return }
        let id = warpGeneration
        let read = readWarp
        isRefreshingWarp = true
        warpError = nil
        onChange?()
        warpTask = Task { [weak self] in
            do {
                let result = try await read(allowInteraction)
                guard let self, id == self.warpGeneration, !Task.isCancelled else { return }
                self.warpSnapshot = result
                self.warpLastSuccessAt = .now
                self.warpFailures = 0
                self.nextWarpRefresh = Date().addingTimeInterval(300)
            } catch {
                guard let self, id == self.warpGeneration, !Task.isCancelled else { return }
                self.warpSnapshot = nil
                let failure = error as? WarpUsageFailure
                self.warpError = failure?.reason ?? error as? WarpReadError ?? .network
                self.warpFailures += 1
                let backoff = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(min(self.warpFailures, 4)))))
                self.nextWarpRefresh = max(backoff, failure?.retryAt ?? .distantPast)
            }
            guard let self, id == self.warpGeneration else { return }
            self.isRefreshingWarp = false
            self.warpTask = nil
            self.onChange?()
        }
    }

    private func cancelWarp() {
        warpGeneration += 1
        warpTask?.cancel()
        warpTask = nil
        isRefreshingWarp = false
    }

    func setMenuSource(_ source: MenuQuotaSource) {
        guard availableMenuSources.contains(source) else { return }
        menuSource = source
        displayedMenuSource = source
        lastMenuRotation = ProcessInfo.processInfo.systemUptime
        defaults.set(source.rawValue, forKey: "quotaMenuSource")
        onChange?()
    }

    func setMenuRotationEnabled(_ enabled: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        menuRotationEnabled = enabled
        defaults.set(enabled, forKey: "quotaMenuRotationEnabled")
        displayedMenuSource = menuSource
        lastMenuRotation = now
        onChange?()
    }

    func setMenuRotationInterval(_ seconds: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        menuRotationInterval = min(60, max(5, seconds))
        defaults.set(menuRotationInterval, forKey: "quotaMenuRotationInterval")
        lastMenuRotation = now
    }

    func advanceMenuRotation(now: TimeInterval = ProcessInfo.processInfo.systemUptime, paused: Bool = false) {
        guard menuRotationEnabled, availableMenuSources.count > 1, !paused else {
            lastMenuRotation = now
            return
        }
        guard now - lastMenuRotation >= Double(menuRotationInterval) else { return }
        let sources = availableMenuSources
        let index = sources.firstIndex(of: displayedMenuSource) ?? 0
        displayedMenuSource = sources[(index + 1) % sources.count]
        lastMenuRotation = now
        onChange?()
    }

    private func normalizeMenuSource() {
        if !availableMenuSources.contains(menuSource), let first = availableMenuSources.first { menuSource = first }
        if !menuRotationEnabled || !availableMenuSources.contains(displayedMenuSource) {
            displayedMenuSource = menuSource
        }
        lastMenuRotation = ProcessInfo.processInfo.systemUptime
        defaults.set(menuSource.rawValue, forKey: "quotaMenuSource")
    }

    func setCodexEnabled(_ enabled: Bool) {
        codexEnabled = enabled
        codex.setMonitoringEnabled(enabled)
        normalizeMenuSource()
        onChange?()
    }

    func setAntigravityEnabled(_ enabled: Bool) {
        antigravityEnabled = enabled
        defaults.set(enabled, forKey: "antigravityEnabled")
        cancelAntigravity()
        antigravityGroups = []
        antigravityError = nil
        failures = 0
        normalizeMenuSource()
        onChange?()
        if enabled { refreshAntigravity() }
    }

    func saveCLIPath(_ value: String) {
        cancelAntigravity()
        cliPath = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(cliPath, forKey: "antigravityCLIPath")
        installation = nil
        antigravityGroups = []
        antigravityLastSuccessAt = nil
        antigravityError = nil
        failures = 0
        nextAntigravityRefresh = .distantPast
        detectCLI()
        onChange?()
        if antigravityEnabled { refreshAntigravity() }
    }

    func detectCLI() {
        detectionGeneration += 1
        let id = detectionGeneration
        detectionTask?.cancel()
        isDetecting = true
        detectionError = nil
        let path = cliPath
        detectionTask = Task { [weak self] in
            do {
                let detected = try await AntigravityReader().detect(pathOverride: path)
                guard let self, id == self.detectionGeneration, !Task.isCancelled else { return }
                self.installation = detected
            } catch {
                guard let self, id == self.detectionGeneration, !Task.isCancelled else { return }
                self.installation = nil
                self.detectionError = error as? ProviderReadError ?? .launchFailed
            }
            guard let self, id == self.detectionGeneration else { return }
            self.isDetecting = false
            self.detectionTask = nil
        }
    }

    func refreshAll() {
        if codexEnabled { codex.refresh() }
        if antigravityEnabled { refreshAntigravity() }
        if claudeEnabled { refreshClaude() }
        if warpEnabled { refreshWarp() }
        if teamoEnabled { refreshTeamo() }
    }

    func tick(now: Date = .now) {
        if codexEnabled {
            let interval: TimeInterval = codex.readError == .rateLimited ? 300 : 30
            if codex.lastRefreshAt.map({ now.timeIntervalSince($0) >= interval }) ?? true { codex.refresh() }
            codex.performScheduledWriteBack()
        }
        if antigravityEnabled, now >= nextAntigravityRefresh,
           antigravityError?.stopsAutomaticRefresh != true { refreshAntigravity() }
        if claudeEnabled, now >= nextClaudeRefresh,
           claudeError?.stopsAutomaticRefresh != true { refreshClaude() }
        if warpEnabled, now >= nextWarpRefresh,
           warpError?.stopsAutomaticRefresh != true { refreshWarp() }
        if teamoEnabled, now >= nextTeamoRefresh,
           teamoError?.stopsAutomaticRefresh != true { refreshTeamo() }
    }

    func setClaudeEnabled(_ enabled: Bool) {
        guard claudeEnabled != enabled else { return }
        let coolingDown = claudeError == .rateLimited && Date() < nextClaudeRefresh
        claudeEnabled = enabled
        defaults.set(enabled, forKey: "claudeEnabled")
        cancelClaude()
        claudeMetrics = []
        claudeError = coolingDown ? .rateLimited : nil
        claudePlanName = "当前登录账号"
        claudeLastSuccessAt = nil
        if !coolingDown { claudeFailures = 0 }
        normalizeMenuSource()
        onChange?()
        if enabled { refreshClaude() }
    }

    // Only explicit verification may show a Keychain permission prompt.
    func refreshClaude(allowInteraction: Bool = false) {
        guard claudeTask == nil else { return }
        // Even manual refresh must respect a server rate-limit cooldown.
        guard claudeError != .rateLimited || Date() >= nextClaudeRefresh else { return }
        let id = claudeGeneration
        let read = readClaude
        isRefreshingClaude = true
        claudeLastAttemptAt = .now
        claudeError = nil
        onChange?()
        claudeTask = Task { [weak self] in
            do {
                let result = try await read(allowInteraction)
                guard let self, id == self.claudeGeneration, !Task.isCancelled else { return }
                self.claudeMetrics = result.metrics
                self.claudePlanName = result.planName
                self.claudeLastSuccessAt = .now
                self.claudeFailures = 0
                self.nextClaudeRefresh = Date().addingTimeInterval(300)
            } catch {
                guard let self, id == self.claudeGeneration, !Task.isCancelled else { return }
                self.claudeMetrics = []
                self.claudePlanName = "当前登录账号"
                let failure = error as? ClaudeUsageFailure
                self.claudeError = failure?.reason ?? error as? ProviderReadError ?? .network
                self.claudeFailures += 1
                let backoff = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(min(self.claudeFailures, 4)))))
                self.nextClaudeRefresh = max(backoff, failure?.retryAt ?? .distantPast)
            }
            guard let self, id == self.claudeGeneration else { return }
            self.isRefreshingClaude = false
            self.claudeTask = nil
            self.onChange?()
        }
    }

    private func cancelClaude() {
        claudeGeneration += 1
        claudeTask?.cancel()
        claudeTask = nil
        isRefreshingClaude = false
    }

    // Explicit validation can query once while disabled; it never enables polling.
    func refreshAntigravity() {
        guard refreshTask == nil else { return }
        let id = generation
        let path = cliPath
        let read = readAntigravity
        isRefreshingAntigravity = true
        antigravityLastAttemptAt = .now
        antigravityError = nil
        onChange?()
        refreshTask = Task { [weak self] in
            do {
                let result = try await read(path)
                guard let self, id == self.generation, !Task.isCancelled else { return }
                self.installation = result.installation
                self.antigravityGroups = result.groups
                self.antigravityLastSuccessAt = .now
                self.failures = 0
                self.nextAntigravityRefresh = Date().addingTimeInterval(60)
            } catch {
                guard let self, id == self.generation, !Task.isCancelled else { return }
                self.antigravityGroups = []
                self.antigravityError = error as? ProviderReadError ?? .network
                self.failures += 1
                self.nextAntigravityRefresh = Date().addingTimeInterval(min(900, 60 * pow(2, Double(min(self.failures, 4)))))
            }
            guard let self, id == self.generation else { return }
            self.isRefreshingAntigravity = false
            self.refreshTask = nil
            self.onChange?()
        }
    }

    private func cancelAntigravity() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshingAntigravity = false
    }

    func stop() {
        cancelTeamo()
        cancelWarp()
        cancelClaude()
        cancelAntigravity()
        detectionGeneration += 1
        detectionTask?.cancel()
        detectionTask = nil
        isDetecting = false
        codex.cancelRefresh()
    }

    var displayedQuotaStatus: RateLimitStatus {
        guard availableMenuSources.contains(displayedMenuSource) else { return .unavailable }
        switch displayedMenuSource {
        case .codex: return codex.rateLimitStatus
        case .teamo:
            if isRefreshingTeamo { return .loading }
            return teamoError == nil && teamoSnapshot != nil ? .live : .unavailable
        case .warp:
            if isRefreshingWarp { return .loading }
            return warpError == nil && warpSnapshot != nil ? .live : .unavailable
        case .claude:
            if isRefreshingClaude { return .loading }
            return claudeError == nil && !claudeMetrics.isEmpty ? .live : .unavailable
        case .antigravityGemini, .antigravityThirdParty:
            if isRefreshingAntigravity { return .loading }
            return antigravityError == nil && !antigravityGroups.isEmpty ? .live : .unavailable
        }
    }

    var displayedQuotaMetrics: [QuotaMetric] {
        guard displayedQuotaStatus == .live || displayedQuotaStatus == .manual else { return [] }
        switch displayedMenuSource {
        case .codex: return Self.codexMetrics(codex)
        case .claude: return claudeMetrics
        case .warp: return warpSnapshot?.metric.map { [$0] } ?? []
        case .teamo: return [] // Money has no quota denominator; never invent a percentage.
        case .antigravityGemini, .antigravityThirdParty:
            return antigravityGroups.first(where: { $0.id == (displayedMenuSource == .antigravityGemini ? "gemini" : "3p") })?.metrics ?? []
        }
    }

    var displayedSourcePrefix: String {
        switch displayedMenuSource {
        case .codex: ""
        case .antigravityGemini: "G "
        case .antigravityThirdParty: "C+G "
        case .claude: "CL "
        case .warp: "W "
        case .teamo: "TR "
        }
    }

    var canRefreshDisplayedSource: Bool {
        availableMenuSources.contains(displayedMenuSource) && displayedQuotaStatus != .loading
            && !(displayedMenuSource == .claude && claudeError == .rateLimited && Date() < nextClaudeRefresh)
            && !(displayedMenuSource == .warp && warpError == .rateLimited && Date() < nextWarpRefresh)
            && !(displayedMenuSource == .teamo && teamoError == .rateLimited && Date() < nextTeamoRefresh)
    }

    func refreshDisplayedSource() {
        guard canRefreshDisplayedSource else { return }
        switch displayedMenuSource {
        case .codex: codex.refresh()
        case .claude: refreshClaude()
        case .warp: refreshWarp()
        case .teamo: refreshTeamo()
        case .antigravityGemini, .antigravityThirdParty: refreshAntigravity()
        }
    }

    var menuLines: (first: String, second: String) {
        guard !availableMenuSources.isEmpty else { return ("未启用", "点击设置") }
        if displayedMenuSource == .teamo {
            guard displayedQuotaStatus == .live, let quota = teamoSnapshot else { return ("TR 余额 —", "今日 —") }
            return ("TR " + quota.balanceText, "今日 " + quota.costText)
        }
        if displayedMenuSource == .warp {
            guard displayedQuotaStatus == .live, let quota = warpSnapshot else { return ("W Credits —", "重置 —") }
            return ("W " + quota.balanceText, "重置 " + (quota.resetsAt?.formatted(.dateTime.month().day()) ?? "—"))
        }
        let metrics = displayedQuotaMetrics
        let prefix = displayedSourcePrefix
        func line(_ window: String, label: String) -> String {
            guard let metric = metrics.first(where: { $0.window == window }) else { return "\(label) — · —" }
            let reset = metric.resetsAt.map {
                window == "weekly" ? $0.formatted(.dateTime.month().day()) : $0.formatted(date: .omitted, time: .shortened)
            } ?? "—"
            return "\(label) \(Int(metric.remainingPercent.rounded()))% · \(reset)"
        }
        return (prefix + line("5h", label: "5小时"), prefix + line("weekly", label: "一周"))
    }

    static func codexMetrics(_ model: UsageModel) -> [QuotaMetric] {
        [("5h", model.fiveHour), ("weekly", model.weekly)].compactMap { window, value in
            value.map { QuotaMetric(id: window, window: window, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) }
        }
    }
}
