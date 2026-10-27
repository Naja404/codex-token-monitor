import AppKit
import Foundation
import SwiftUI
import UserNotifications

enum LocalAlertKind: String, CaseIterable, Codable, Sendable {
    case lowQuota, recovery, refreshFailure, signIn
    var title: String {
        switch self {
        case .lowQuota: L10n.text("低额度提醒")
        case .recovery: L10n.text("额度恢复提醒")
        case .refreshFailure: L10n.text("刷新失败提醒")
        case .signIn: L10n.text("登录失效提醒")
        }
    }
}

struct LocalNotificationPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var kinds: Set<LocalAlertKind> = [.lowQuota]
    var percentThreshold = 20.0
    var balanceThreshold = 5.0
    var sound = true
    mutating func normalize() {
        percentThreshold = percentThreshold.isFinite ? min(95, max(0, percentThreshold)) : 20
        balanceThreshold = balanceThreshold.isFinite ? min(1000, max(0, balanceThreshold)) : 5
    }
}

struct NotificationLevel: Sendable {
    enum Unit: Sendable, Equatable { case percent, dollars }
    let id: String
    let title: String
    let value: Double
    var unit: Unit = .percent
    var valid: Bool { value.isFinite && value >= 0 && (unit == .dollars || value <= 100) }
    var summary: String {
        title + " " + (unit == .percent ? value.formatted(.number.precision(.fractionLength(0...1))) + "%"
            : value.formatted(.currency(code: "USD")))
    }
}

struct NotificationObservation: Sendable {
    enum Result: Sendable { case success([NotificationLevel]), failure(credentials: Bool, terminal: Bool) }
    let source: String
    let title: String
    let sample: String
    let result: Result
}

struct LocalQuotaAlert: Sendable {
    let source: String
    let sourceTitle: String
    let kind: LocalAlertKind
    var details: String = ""
    var levelIDs: Set<String> = []
    var title: String { source == "test" ? L10n.text("测试通知") : sourceTitle + " · " + kind.title }
    var body: String {
        if source == "test" { return details }
        switch kind {
        case .lowQuota: return L10n.format("剩余额度已达到提醒阈值：%@", details)
        case .recovery: return L10n.format("剩余额度已恢复：%@", details)
        case .refreshFailure: return L10n.text("额度刷新持续失败或已暂停。请打开应用查看详情。")
        case .signIn: return L10n.text("登录或密钥不可用，请打开供应商设置重新验证。")
        }
    }
}

/// Only fresh completed reads enter this policy. Menu caches and loading states never do.
struct LocalNotificationPolicy: Codable, Equatable {
    struct State: Codable, Equatable {
        var lastSample: String?
        var low: Set<String> = []
        var announcedLow: Set<String> = []
        var failures = 0
        var announcedFailure = false
        var announcedSignIn = false
    }
    var states: [String: State] = [:]

    mutating func retainSources(_ active: Set<String>) { states = states.filter { active.contains($0.key) } }

    mutating func preferencesChanged(from old: LocalNotificationPreferences, to new: LocalNotificationPreferences) {
        for key in states.keys {
            states[key]?.lastSample = nil
            if old.percentThreshold != new.percentThreshold || old.balanceThreshold != new.balanceThreshold {
                states[key]?.low = []; states[key]?.announcedLow = []
            }
        }
    }

    mutating func evaluate(_ observation: NotificationObservation, preferences p: LocalNotificationPreferences) -> [LocalQuotaAlert] {
        guard p.enabled else { return [] }
        var state = states[observation.source] ?? State()
        guard state.lastSample != observation.sample else { return [] }
        state.lastSample = observation.sample
        var alerts: [LocalQuotaAlert] = []
        func alert(_ kind: LocalAlertKind, levels: [NotificationLevel] = []) -> LocalQuotaAlert {
            .init(source: observation.source, sourceTitle: observation.title, kind: kind,
                  details: levels.map(\.summary).joined(separator: " · "), levelIDs: Set(levels.map(\.id)))
        }
        switch observation.result {
        case let .failure(credentials, terminal):
            if credentials {
                state.failures = 0
                if p.kinds.contains(.signIn), !state.announcedSignIn {
                    alerts.append(alert(.signIn)); state.announcedSignIn = true
                }
            } else {
                state.failures += 1
                if p.kinds.contains(.refreshFailure), !state.announcedFailure, terminal || state.failures >= 3 {
                    alerts.append(alert(.refreshFailure)); state.announcedFailure = true
                }
            }
        case let .success(levels):
            state.failures = 0; state.announcedFailure = false; state.announcedSignIn = false
            var low: [NotificationLevel] = [], recovered: [NotificationLevel] = []
            for level in levels where level.valid {
                let threshold = level.unit == .percent ? p.percentThreshold : p.balanceThreshold
                let margin = level.unit == .percent ? 5 : max(0.5, threshold * 0.1)
                if level.value <= threshold {
                    state.low.insert(level.id)
                    if p.kinds.contains(.lowQuota), !state.announcedLow.contains(level.id) {
                        low.append(level); state.announcedLow.insert(level.id)
                    }
                } else if level.value >= threshold + margin {
                    if state.low.remove(level.id) != nil, p.kinds.contains(.recovery) { recovered.append(level) }
                    state.announcedLow.remove(level.id)
                }
            }
            if !low.isEmpty { alerts.append(alert(.lowQuota, levels: low)) }
            if !recovered.isEmpty { alerts.append(alert(.recovery, levels: recovered)) }
        }
        states[observation.source] = state
        return alerts
    }

    mutating func deliveryFailed(_ alert: LocalQuotaAlert) {
        states[alert.source]?.lastSample = nil
        switch alert.kind {
        case .lowQuota: states[alert.source]?.announcedLow.subtract(alert.levelIDs)
        case .recovery: states[alert.source]?.low.formUnion(alert.levelIDs)
        case .refreshFailure: states[alert.source]?.announcedFailure = false
        case .signIn: states[alert.source]?.announcedSignIn = false
        }
    }
}

enum LocalNotificationAuthorization: Sendable, Equatable {
    case unknown, notDetermined, denied, allowed, unavailable
    var title: String {
        switch self {
        case .unknown: L10n.text("正在读取通知权限…")
        case .notDetermined: L10n.text("尚未申请通知权限")
        case .denied: L10n.text("系统未允许通知，请到系统设置 → 通知中开启。")
        case .allowed: L10n.text("系统已允许通知")
        case .unavailable: L10n.text("请从应用程序运行已安装的 App，以使用系统通知。")
        }
    }
}

enum SystemLocalNotifications {
    enum Failure: Error { case unavailable, denied }
    static var isBundledApp: Bool { Bundle.main.bundleIdentifier == "com.hisoka.codex-token-monitor" }
    static func authorization() async -> LocalNotificationAuthorization {
        guard isBundledApp else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    static func request() async throws -> Bool {
        guard isBundledApp else { throw Failure.unavailable }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func send(_ alert: LocalQuotaAlert, sound: Bool) async throws {
        guard isBundledApp else { throw Failure.unavailable }
        guard await authorization() == .allowed else { throw Failure.denied }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = "quota." + alert.source
        if sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(.init(identifier: "quota." + UUID().uuidString,
                                                              content: content, trigger: nil))
    }
    static func cancelPending() {
        if isBundledApp { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
    }
}

@MainActor final class LocalNotificationController: ObservableObject {
    @Published private(set) var preferences: LocalNotificationPreferences
    @Published private(set) var authorization: LocalNotificationAuthorization = .unknown
    @Published private(set) var requestingPermission = false
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private var policy: LocalNotificationPolicy
    private let getAuthorization: @Sendable () async -> LocalNotificationAuthorization
    private let requestAuthorization: @Sendable () async throws -> Bool
    private let send: @Sendable (LocalQuotaAlert, Bool) async throws -> Void
    private let cancelPending: @Sendable () -> Void
    private var worker: Task<Void, Never>?
    var isDelivering: Bool { worker != nil }
    private var generation = 0
    private var retryAfter = Date.distantPast
    private var activeSources: Set<String> = []

    init(defaults: UserDefaults = .standard,
         getAuthorization: @escaping @Sendable () async -> LocalNotificationAuthorization = { await SystemLocalNotifications.authorization() },
         requestAuthorization: @escaping @Sendable () async throws -> Bool = { try await SystemLocalNotifications.request() },
         send: @escaping @Sendable (LocalQuotaAlert, Bool) async throws -> Void = { try await SystemLocalNotifications.send($0, sound: $1) },
         cancelPending: @escaping @Sendable () -> Void = { SystemLocalNotifications.cancelPending() }) {
        self.defaults = defaults
        self.getAuthorization = getAuthorization; self.requestAuthorization = requestAuthorization
        self.send = send; self.cancelPending = cancelPending
        var p = defaults.data(forKey: "localNotificationPreferences").flatMap { try? JSONDecoder().decode(LocalNotificationPreferences.self, from: $0) } ?? .init()
        p.normalize(); preferences = p
        policy = defaults.data(forKey: "localNotificationLedger").flatMap { try? JSONDecoder().decode(LocalNotificationPolicy.self, from: $0) } ?? .init()
    }

    func refreshAuthorization() async { authorization = await getAuthorization() }

    func setEnabled(_ enabled: Bool) async {
        generation += 1
        let id = generation
        if !enabled {
            worker?.cancel(); worker = nil; cancelPending()
            update { $0.enabled = false }
            return
        }
        requestingPermission = true; message = nil
        defer { requestingPermission = false }
        await refreshAuthorization()
        if authorization == .notDetermined {
            do { _ = try await requestAuthorization(); await refreshAuthorization() }
            catch { message = L10n.text("通知授权失败，请稍后重试。"); return }
        }
        guard id == generation else { return }
        update { $0.enabled = authorization == .allowed }
        if authorization != .allowed { message = authorization.title }
    }

    func update(_ change: (inout LocalNotificationPreferences) -> Void) {
        let old = preferences
        var updated = old; change(&updated); updated.normalize()
        guard updated != old else { return }
        preferences = updated
        policy.preferencesChanged(from: old, to: updated)
        defaults.set(try? JSONEncoder().encode(updated), forKey: "localNotificationPreferences")
    }

    func observe(_ observations: [NotificationObservation], activeSources: Set<String>, now: Date = .now) {
        self.activeSources = activeSources
        guard preferences.enabled, authorization == .allowed, worker == nil, now >= retryAfter else { return }
        let previousPolicy = policy
        policy.retainSources(activeSources)
        let id = generation
        worker = Task { [weak self] in
            guard let self else { return }
            for observation in observations {
                guard !Task.isCancelled, id == self.generation, self.preferences.enabled else { break }
                guard self.activeSources.contains(observation.source) else { continue }
                let alerts = self.policy.evaluate(observation, preferences: self.preferences)
                for alert in alerts {
                    guard self.preferences.kinds.contains(alert.kind), self.activeSources.contains(alert.source),
                          !Task.isCancelled, self.authorization == .allowed else {
                        self.policy.deliveryFailed(alert); continue
                    }
                    do {
                        try await self.send(alert, self.preferences.sound)
                        self.message = nil
                    }
                    catch {
                        self.policy.deliveryFailed(alert)
                        self.retryAfter = now.addingTimeInterval(60)
                        self.message = L10n.text("通知发送失败，稍后自动重试。")
                        self.authorization = await self.getAuthorization()
                    }
                    if id != self.generation || !self.preferences.enabled { self.cancelPending(); break }
                }
            }
            if self.policy != previousPolicy {
                self.defaults.set(try? JSONEncoder().encode(self.policy), forKey: "localNotificationLedger")
            }
            if id == self.generation { self.worker = nil }
        }
    }

    func sendTest() async {
        guard preferences.enabled, !requestingPermission else { return }
        await refreshAuthorization()
        guard authorization == .allowed else { message = authorization.title; return }
        do {
            try await send(.init(source: "test", sourceTitle: "Codex Token Monitor", kind: .lowQuota,
                                 details: L10n.text("这是一条本地测试通知。")), preferences.sound)
            message = L10n.text("测试通知已提交；显示方式由系统通知设置和专注模式决定。")
        } catch { message = L10n.text("通知发送失败，稍后自动重试。") }
    }
}
