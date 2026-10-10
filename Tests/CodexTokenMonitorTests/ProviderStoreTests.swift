import Foundation
import Testing
@testable import CodexTokenMonitor

@MainActor
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "provider-tests-\(UUID().uuidString)")!
}

@MainActor private func waitUntilSettled(_ store: ProviderStore) async throws {
    for _ in 0..<200 {
        if !store.isRefreshingAntigravity { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Quota query did not settle")
}

private actor QuotaProbe {
    var calls = 0
    let error: ProviderReadError
    init(error: ProviderReadError = .network) { self.error = error }
    func read() throws -> AntigravitySnapshot {
        calls += 1
        if calls > 1 { throw error }
        return AntigravitySnapshot(installation: .init(path: "/test/agy", version: "1.3.2"),
                                  groups: try AntigravityReport.parse(antigravityFixture))
    }
}

@Test @MainActor func providerPreferencesDefaultAndPersist() {
    let defaults = isolatedDefaults()
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults)
    #expect(store.codexEnabled)
    #expect(!store.antigravityEnabled)
    #expect(store.menuSource == .codex)
    store.setCodexEnabled(false)
    #expect(store.availableMenuSources.isEmpty)
    #expect(store.menuLines.first == "未启用")
    let restored = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(!restored.codexEnabled)
}

@Test @MainActor func sourceFallsBackWhenProviderIsDisabled() {
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "antigravityEnabled")
    defaults.set("antigravityGemini", forKey: "quotaMenuSource")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(store.menuSource == .antigravityGemini)
    store.setAntigravityEnabled(false)
    #expect(store.menuSource == .codex)
}

@Test @MainActor func disabledCodexDoesNotReadOrWrite() async {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "codexEnabled")
    let model = UsageModel(defaults: defaults, readUsage: {
        Issue.record("Disabled Codex must not read credentials or query the API")
        throw ProviderReadError.network
    })
    model.refresh()
    let result = await model.writeBack(apiURL: "https://example.com", bearer: "test", codexKeyID: "test")
    #expect(result == .failure("Codex 监控已关闭"))
    #expect(model.rateLimitStatus == .unavailable)
}

@Test @MainActor func disabledAntigravityDoesNotPoll() async {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "codexEnabled")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readAntigravity: { _ in
        Issue.record("Disabled Antigravity must not launch a CLI")
        throw ProviderReadError.network
    })
    store.refreshAll()
    store.tick(now: .distantFuture)
    #expect(!store.isRefreshingAntigravity)
    #expect(store.antigravityGroups.isEmpty)
}

@Test @MainActor func ignoresLateAntigravityResultAfterDisable() async throws {
    let defaults = isolatedDefaults()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readAntigravity: { _ in
        try? await Task.sleep(for: .milliseconds(30))
        return AntigravitySnapshot(installation: .init(path: "/test/agy", version: "1.3.2"),
                                  groups: try AntigravityReport.parse(antigravityFixture))
    })
    store.setAntigravityEnabled(true)
    await Task.yield()
    store.setAntigravityEnabled(false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.antigravityGroups.isEmpty)
    #expect(store.antigravityLastSuccessAt == nil)
    #expect(!store.isRefreshingAntigravity)
}

@Test @MainActor func preventsDuplicateCLIQueriesAndShowsIndependentSuccess() async throws {
    let defaults = isolatedDefaults()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readAntigravity: { _ in
        try await Task.sleep(for: .milliseconds(20))
        return AntigravitySnapshot(installation: .init(path: "/test/agy", version: "1.3.2"),
                                  groups: try AntigravityReport.parse(antigravityFixture))
    })
    store.setAntigravityEnabled(true)
    let attempt = store.antigravityLastAttemptAt
    store.refreshAntigravity()
    #expect(store.antigravityLastAttemptAt == attempt)
    try await waitUntilSettled(store)
    #expect(store.antigravityGroups.count == 2)
    #expect(store.antigravityLastSuccessAt != nil)
    #expect(store.codex.lastSuccessAt == nil)
    store.setMenuSource(.antigravityThirdParty)
    #expect(store.menuLines.first.contains("0%"))
    store.stop()
}

@Test @MainActor func failedRefreshClearsQuotaAndBacksOff() async throws {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "codexEnabled")
    let probe = QuotaProbe()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readAntigravity: { _ in try await probe.read() })
    store.setAntigravityEnabled(true)
    try await waitUntilSettled(store)
    let success = store.antigravityLastSuccessAt
    store.refreshAntigravity()
    try await waitUntilSettled(store)
    #expect(store.antigravityGroups.isEmpty)
    #expect(store.antigravityError == .network)
    #expect(store.antigravityLastSuccessAt == success)
    #expect(store.nextAntigravityRefresh.timeIntervalSinceNow > 100)
    #expect(store.menuLines.first.contains("—"))
    store.tick()
    #expect(await probe.calls == 2)
    store.stop()
}

@Test @MainActor func invalidCredentialsPauseAutomaticQueries() async throws {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "codexEnabled")
    let probe = QuotaProbe(error: .missingCredentials)
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readAntigravity: { _ in try await probe.read() })
    store.setAntigravityEnabled(true)
    try await waitUntilSettled(store)
    store.refreshAntigravity()
    try await waitUntilSettled(store)
    store.tick(now: .distantFuture)
    #expect(!store.isRefreshingAntigravity)
    #expect(await probe.calls == 2)
    store.stop()
}

@Test @MainActor func validationWhileDisabledDoesNotEnablePolling() async throws {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: "codexEnabled")
    let probe = QuotaProbe()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readAntigravity: { _ in try await probe.read() })
    store.refreshAntigravity()
    try await waitUntilSettled(store)
    #expect(!store.antigravityEnabled)
    #expect(store.antigravityLastSuccessAt != nil)
    store.tick(now: .distantFuture)
    #expect(await probe.calls == 1)
    store.stop()
}

@Test @MainActor func ignoresLateCodexResultAfterDisable() async throws {
    let defaults = isolatedDefaults()
    let model = UsageModel(defaults: defaults, readUsage: {
        try? await Task.sleep(for: .milliseconds(30))
        return LiveRateLimits(primary: .init(usedPercent: 10, resetsAt: 1_800_000_000),
                              secondary: nil, planName: "Pro", additional: [])
    })
    model.refresh()
    await Task.yield()
    model.setMonitoringEnabled(false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(model.fiveHour == nil)
    #expect(model.lastSuccessAt == nil)
    #expect(model.rateLimitStatus == .unavailable)
}
