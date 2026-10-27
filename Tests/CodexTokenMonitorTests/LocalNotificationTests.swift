import Foundation
import Testing
@testable import CodexTokenMonitor

private func notificationSample(_ value: Double, sample: String = UUID().uuidString,
                                dollars: Bool = false) -> NotificationObservation {
    .init(source: "codex", title: "Codex", sample: sample,
          result: .success([.init(id: "weekly", title: "Weekly", value: value, unit: dollars ? .dollars : .percent)]))
}
private func allNotificationPreferences() -> LocalNotificationPreferences {
    var p = LocalNotificationPreferences(); p.enabled = true; p.kinds = Set(LocalAlertKind.allCases); return p
}

@Test func quotaNotificationsAreDeduplicatedUntilRealRecoveryAndSurviveRestart() throws {
    var engine = LocalNotificationPolicy()
    let p = allNotificationPreferences()
    #expect(engine.evaluate(notificationSample(20, sample: "first"), preferences: p).map(\.kind) == [.lowQuota])
    #expect(engine.evaluate(notificationSample(20, sample: "first"), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(19), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(22), preferences: p).isEmpty)
    engine = try JSONDecoder().decode(LocalNotificationPolicy.self, from: JSONEncoder().encode(engine))
    #expect(engine.evaluate(notificationSample(18), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(25), preferences: p).map(\.kind) == [.recovery])
    #expect(engine.evaluate(notificationSample(0), preferences: p).map(\.kind) == [.lowQuota])
}

@Test func notificationCategoriesCanBeIndependentlySelected() {
    var engine = LocalNotificationPolicy(), p = allNotificationPreferences()
    p.kinds = [.recovery]
    #expect(engine.evaluate(notificationSample(80), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(10), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(70), preferences: p).map(\.kind) == [.recovery])
    p.kinds = []
    #expect(engine.evaluate(notificationSample(0, sample: "current"), preferences: p).isEmpty)
    let old = p; p.kinds = [.lowQuota]; engine.preferencesChanged(from: old, to: p)
    #expect(engine.evaluate(notificationSample(0, sample: "current"), preferences: p).map(\.kind) == [.lowQuota])
    p.enabled = false
    #expect(engine.evaluate(notificationSample(0), preferences: p).isEmpty)
}

@Test func invalidAndMissingQuotaNeverBecomeZeroOrRecovery() {
    var engine = LocalNotificationPolicy(); let p = allNotificationPreferences()
    for value in [Double.nan, .infinity, -.infinity, -1, 101] {
        #expect(engine.evaluate(notificationSample(value), preferences: p).isEmpty)
    }
    #expect(engine.evaluate(notificationSample(0), preferences: p).map(\.kind) == [.lowQuota])
    #expect(engine.evaluate(.init(source: "codex", title: "Codex", sample: "missing", result: .success([])), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(15), preferences: p).isEmpty)
}

@Test func balanceAndPercentNotificationsUseIndependentThresholdsAndGroupWindows() {
    var engine = LocalNotificationPolicy(); let p = allNotificationPreferences()
    #expect(engine.evaluate(notificationSample(6, dollars: true), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(5, dollars: true), preferences: p).map(\.kind) == [.lowQuota])
    #expect(engine.evaluate(notificationSample(5.3, dollars: true), preferences: p).isEmpty)
    #expect(engine.evaluate(notificationSample(5.5, dollars: true), preferences: p).map(\.kind) == [.recovery])
    #expect(engine.evaluate(notificationSample(-1, dollars: true), preferences: p).map(\.kind) == [.lowQuota])
    let grouped = NotificationObservation(source: "claude", title: "Claude Code", sample: "both", result: .success([
        .init(id: "5h", title: "5h", value: 0), .init(id: "weekly", title: "Weekly", value: 10)]))
    let alerts = engine.evaluate(grouped, preferences: p)
    #expect(alerts.count == 1)
    #expect(alerts.first?.levelIDs == ["5h", "weekly"])
}

@Test func errorsNeedDistinctCompletedReadsAndCredentialsHaveTheirOwnCategory() {
    var engine = LocalNotificationPolicy(); let p = allNotificationPreferences()
    func failure(_ id: String, credentials: Bool = false, terminal: Bool = false) -> NotificationObservation {
        .init(source: "codex", title: "Codex", sample: id, result: .failure(credentials: credentials, terminal: terminal))
    }
    for _ in 0..<10 { #expect(engine.evaluate(failure("one"), preferences: p).isEmpty) }
    #expect(engine.evaluate(failure("two"), preferences: p).isEmpty)
    #expect(engine.evaluate(failure("three"), preferences: p).map(\.kind) == [.refreshFailure])
    #expect(engine.evaluate(failure("four"), preferences: p).isEmpty)
    #expect(engine.evaluate(failure("auth", credentials: true), preferences: p).map(\.kind) == [.signIn])
    #expect(engine.evaluate(failure("auth-again", credentials: true), preferences: p).isEmpty)
    _ = engine.evaluate(notificationSample(80), preferences: p)
    #expect(engine.evaluate(failure("auth-after-success", credentials: true), preferences: p).map(\.kind) == [.signIn])
    _ = engine.evaluate(notificationSample(80), preferences: p)
    #expect(engine.evaluate(failure("cli-stopped", terminal: true), preferences: p).map(\.kind) == [.refreshFailure])
}

@Test func disablingProviderAndFailedDeliveryAllowAValidRetry() {
    var engine = LocalNotificationPolicy(); let p = allNotificationPreferences()
    let observation = notificationSample(0, sample: "same")
    let first = engine.evaluate(observation, preferences: p)
    engine.deliveryFailed(first[0])
    #expect(engine.evaluate(observation, preferences: p).count == 1)
    engine.retainSources([])
    #expect(engine.evaluate(observation, preferences: p).count == 1)
}

private actor NotificationSpy {
    var status = LocalNotificationAuthorization.notDetermined
    var requests = 0
    var sent: [LocalQuotaAlert] = []
    func authorization() -> LocalNotificationAuthorization { status }
    func setStatus(_ value: LocalNotificationAuthorization) { status = value }
    func request() -> Bool { requests += 1; status = .allowed; return true }
    func record(_ alert: LocalQuotaAlert) { sent.append(alert) }
}

@MainActor private func waitForNotificationDelivery(_ controller: LocalNotificationController) async throws {
    for _ in 0..<200 where controller.isDelivering { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!controller.isDelivering)
}

@Test @MainActor func notificationOptInRequestsPermissionOnlyOnEnableAndPersistsDeduplication() async throws {
    let name = "notification-optin-\(UUID())", spy = NotificationSpy()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    func make() -> LocalNotificationController {
        .init(defaults: defaults, getAuthorization: { await spy.authorization() },
              requestAuthorization: { await spy.request() }, send: { alert, _ in await spy.record(alert) }, cancelPending: {})
    }
    let controller = make()
    #expect(!controller.preferences.enabled)
    controller.observe([notificationSample(0)], activeSources: ["codex"])
    #expect(await spy.requests == 0)
    #expect(await spy.sent.isEmpty)
    await controller.setEnabled(true)
    #expect(await spy.requests == 1)
    #expect(controller.preferences.enabled)
    controller.observe([notificationSample(0)], activeSources: ["codex"])
    try await waitForNotificationDelivery(controller)
    #expect(await spy.sent.count == 1)
    let restarted = make()
    await restarted.refreshAuthorization()
    restarted.observe([notificationSample(0)], activeSources: ["codex"])
    try await waitForNotificationDelivery(restarted)
    #expect(await spy.sent.count == 1)
    await restarted.setEnabled(false)
    restarted.observe([notificationSample(0)], activeSources: ["codex"])
    #expect(await spy.sent.count == 1)
}

@Test @MainActor func deniedNotificationPermissionDoesNotEnableAlertsOrRepeatedlyPrompt() async throws {
    let name = "notification-denied-\(UUID())", spy = NotificationSpy()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    await spy.setStatus(.denied)
    let controller = LocalNotificationController(defaults: defaults, getAuthorization: { await spy.authorization() },
        requestAuthorization: { await spy.request() }, send: { alert, _ in await spy.record(alert) }, cancelPending: {})
    await controller.setEnabled(true)
    #expect(!controller.preferences.enabled)
    #expect(controller.authorization == .denied)
    #expect(await spy.requests == 0)
    controller.observe([notificationSample(0)], activeSources: ["codex"])
    #expect(await spy.sent.isEmpty)
}

@Test @MainActor func lateNotificationPermissionCannotUndoDisable() async throws {
    let name = "notification-late-permission-\(UUID())", spy = NotificationSpy()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = LocalNotificationController(defaults: defaults, getAuthorization: { await spy.authorization() },
        requestAuthorization: { try await Task.sleep(for: .milliseconds(30)); return await spy.request() },
        send: { _, _ in }, cancelPending: {})
    let enable = Task { await controller.setEnabled(true) }
    try await Task.sleep(for: .milliseconds(5))
    await controller.setEnabled(false)
    await enable.value
    #expect(!controller.preferences.enabled)
}

@Test @MainActor func providerNotificationSnapshotsNeverUseStaleMenuValues() async throws {
    let name = "notification-live-only-\(UUID())", reader = NotificationReader()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "codexEnabled")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readAntigravity: { _ in try await reader.read() })
    defer { store.stop() }
    store.setAntigravityEnabled(true)
    #expect(store.localNotificationObservations.isEmpty)
    for _ in 0..<200 where store.isRefreshingAntigravity { try await Task.sleep(for: .milliseconds(2)) }
    #expect(store.localNotificationObservations.contains { $0.source == MenuQuotaSource.antigravityGemini.rawValue })
    store.refreshAntigravity()
    #expect(store.localNotificationObservations.isEmpty)
    for _ in 0..<200 where store.isRefreshingAntigravity { try await Task.sleep(for: .milliseconds(2)) }
    #expect(store.menuLines.first.contains("10%"))
    #expect(store.localNotificationObservations.count == 1)
    guard case .failure = store.localNotificationObservations[0].result else { Issue.record("Cached quota was treated as a fresh read"); return }
    store.setAntigravityEnabled(false)
    #expect(store.localNotificationObservations.isEmpty)
}

private actor NotificationReader {
    var count = 0
    func read() async throws -> AntigravitySnapshot {
        count += 1
        try await Task.sleep(for: .milliseconds(10))
        if count > 1 { throw ProviderReadError.network }
        return .init(installation: .init(path: "/test/agy", version: "1.4.7"), groups: [
            .init(id: "gemini", name: "Gemini", metrics: [.init(id: "5h", window: "5h", remainingPercent: 10, resetsAt: nil)])])
    }
}

@Test @MainActor func failedSystemDeliveryRetriesAfterCooldownWithoutLosingTheAlert() async throws {
    let name = "notification-delivery-retry-\(UUID())", delivery = NotificationDeliveryFailure()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = LocalNotificationController(defaults: defaults, getAuthorization: { .allowed },
        requestAuthorization: { Issue.record("Already authorized"); return false },
        send: { _, _ in try await delivery.send() }, cancelPending: {})
    await controller.setEnabled(true)
    let now = Date(), observation = notificationSample(0, sample: "retry")
    controller.observe([observation], activeSources: ["codex"], now: now)
    try await waitForNotificationDelivery(controller)
    #expect(await delivery.attempts == 1)
    controller.observe([observation], activeSources: ["codex"], now: now.addingTimeInterval(30))
    #expect(!controller.isDelivering)
    #expect(await delivery.attempts == 1)
    controller.observe([observation], activeSources: ["codex"], now: now.addingTimeInterval(61))
    try await waitForNotificationDelivery(controller)
    #expect(await delivery.attempts == 2)
}

private actor NotificationDeliveryFailure {
    enum Failure: Error { case failed }
    var attempts = 0
    func send() throws { attempts += 1; if attempts == 1 { throw Failure.failed } }
}

@Test func notificationPreferencesRejectInvalidThresholds() {
    var p = LocalNotificationPreferences()
    p.percentThreshold = .nan; p.balanceThreshold = .infinity; p.normalize()
    #expect(p.percentThreshold == 20 && p.balanceThreshold == 5)
    p.percentThreshold = 1000; p.balanceThreshold = -10; p.normalize()
    #expect(p.percentThreshold == 95 && p.balanceThreshold == 0)
}

@Test @MainActor func disablingAProviderDropsItsQueuedNotification() async throws {
    let name = "notification-disabled-queue-\(UUID())", spy = NotificationSpy()
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = LocalNotificationController(defaults: defaults, getAuthorization: { .allowed },
        requestAuthorization: { true }, send: { alert, _ in
            try await Task.sleep(for: .milliseconds(30)); await spy.record(alert)
        }, cancelPending: {})
    await controller.setEnabled(true)
    controller.observe([notificationSample(0),
        .init(source: "claude", title: "Claude Code", sample: "queued", result: .success([.init(id: "weekly", title: "Weekly", value: 0)]))],
        activeSources: ["codex", "claude"])
    try await Task.sleep(for: .milliseconds(5))
    controller.observe([], activeSources: ["codex"])
    try await waitForNotificationDelivery(controller)
    #expect(await spy.sent.count == 1)
    #expect(await spy.sent.first?.source == "codex")
}
