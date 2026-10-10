import AppKit
import Foundation
import Testing
@testable import CodexTokenMonitor

let claudeUsageFixture = #"{"five_hour":{"utilization":27.5,"resets_at":"2026-10-10T12:50:00.000Z"},"seven_day":{"utilization":82,"resets_at":"2026-10-16T08:48:00Z"},"seven_day_sonnet":{"utilization":10,"resets_at":null}}"#

@Test func claudeUsageConvertsUsedToRemainingWithoutMixingModelLimits() throws {
    let metrics = try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8))
    #expect(metrics.map(\.window) == ["5h", "weekly"])
    #expect(metrics.map(\.remainingPercent) == [72.5, 18])
    #expect(metrics.allSatisfy { $0.resetsAt != nil })
    let partial = try ClaudeUsageReport.parse(Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8))
    #expect(partial.count == 1)
    #expect(partial[0].remainingPercent == 100)
    #expect(partial[0].resetsAt == nil)
}

@Test(arguments: ["{}", #"{"five_hour":{"utilization":true}}"#,
                  #"{"five_hour":{"utilization":-1}}"#, #"{"seven_day":{"utilization":101}}"#,
                  #"{"five_hour":{"utilization":"20"}}"#])
func claudeUsageRejectsUnknownAndInvalidQuota(json: String) {
    #expect(throws: ProviderReadError.invalidResponse) { try ClaudeUsageReport.parse(Data(json.utf8)) }
}

@Test func claudeCredentialsRequireSubscriptionOAuthAndRejectExpiredTokens() throws {
    let now = Date(timeIntervalSince1970: 100)
    let valid = Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":200000,"scopes":["user:profile"],"subscriptionType":"max"}}"#.utf8)
    let credential = try ClaudeCredential.parse(valid, now: now)
    #expect(credential.accessToken == "test-token")
    #expect(credential.planName == "Max")
    #expect(throws: ProviderReadError.credentialsExpired) { try ClaudeCredential.parse(valid, now: .init(timeIntervalSince1970: 201)) }
    #expect(throws: ProviderReadError.missingCredentials) { try ClaudeCredential.parse(Data(#"{"apiKey":"test"}"#.utf8)) }
    #expect(throws: ProviderReadError.permissionDenied) {
        try ClaudeCredential.parse(Data(#"{"claudeAiOauth":{"accessToken":"test","scopes":["user:inference"]}}"#.utf8))
    }
}

@Test func claudeRequestOnlyTargetsAnthropicAndClassifiesFailures() throws {
    let request = DirectClaudeUsageReader.request(accessToken: "test-only")
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    for (code, error) in [(401, ProviderReadError.credentialsExpired), (403, .permissionDenied), (429, .rateLimited), (503, .http(503))] {
        #expect(throws: error) { try DirectClaudeUsageReader.validate(statusCode: code) }
    }
    try DirectClaudeUsageReader.validate(statusCode: 200)
}

@MainActor private func settleClaude(_ store: ProviderStore) async throws {
    for _ in 0..<200 {
        if !store.isRefreshingClaude { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Claude did not settle")
}

private actor ClaudeProbe {
    var calls = 0
    func read() throws -> ClaudeUsageSnapshot {
        calls += 1
        if calls > 1 { throw ProviderReadError.credentialsExpired }
        return .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max")
    }
}

@Test @MainActor func claudeIsOptInAndErrorsStopPollingWithoutStaleQuota() async throws {
    let name = "claude-store-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "codexEnabled")
    let probe = ClaudeProbe()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readClaude: { _ in try await probe.read() })
    defer { store.stop() }
    #expect(!store.claudeEnabled)
    store.refreshAll()
    store.tick(now: .distantFuture)
    #expect(await probe.calls == 0)
    store.setClaudeEnabled(true)
    store.refreshClaude() // Duplicate query is ignored.
    try await settleClaude(store)
    #expect(await probe.calls == 1)
    #expect(store.menuSource == .claude)
    #expect(store.menuLines.first.hasPrefix("CL 5小时 73%"))
    #expect(store.nextClaudeRefresh.timeIntervalSinceNow > 290)
    let success = store.claudeLastSuccessAt
    store.refreshClaude()
    try await settleClaude(store)
    #expect(store.claudeMetrics.isEmpty)
    #expect(store.claudeError == .credentialsExpired)
    #expect(store.claudeLastSuccessAt == success)
    store.tick(now: .distantFuture)
    #expect(await probe.calls == 2)
    store.setClaudeEnabled(false)
    #expect(store.availableMenuSources.isEmpty)
    #expect(!defaults.bool(forKey: "claudeEnabled"))
}

@Test @MainActor func claudeDisableIgnoresLateResults() async throws {
    let name = "claude-cancel-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readClaude: { _ in
        try? await Task.sleep(for: .milliseconds(30))
        return .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Pro")
    })
    defer { store.stop() }
    store.setClaudeEnabled(true)
    await Task.yield()
    store.setClaudeEnabled(false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.claudeMetrics.isEmpty)
    #expect(store.claudeLastSuccessAt == nil)
    #expect(!store.isRefreshingClaude)
}

@Test @MainActor func claudeValidationWhileDisabledDoesNotEnablePolling() async throws {
    let name = "claude-verify-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "codexEnabled")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readClaude: { allowInteraction in
        #expect(allowInteraction)
        return .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max")
    })
    defer { store.stop() }
    store.refreshClaude(allowInteraction: true)
    try await settleClaude(store)
    #expect(!store.claudeEnabled)
    #expect(store.claudeLastSuccessAt != nil)
    store.tick(now: .distantFuture)
    #expect(!store.isRefreshingClaude)
    #expect(store.displayedQuotaMetrics.isEmpty)
}

@Test @MainActor func claudeRateLimitRespectsRetryAfterEvenForManualRefresh() async throws {
    let name = "claude-cooldown-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let retry = Date().addingTimeInterval(7200)
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readClaude: { _ in
        throw ClaudeUsageFailure(reason: .rateLimited, retryAt: retry)
    })
    defer { store.stop() }
    store.setClaudeEnabled(true)
    try await settleClaude(store)
    store.setMenuSource(.claude)
    #expect(store.nextClaudeRefresh == retry)
    #expect(!store.canRefreshDisplayedSource)
    store.refreshClaude(allowInteraction: true)
    #expect(!store.isRefreshingClaude)
    #expect(store.displayedQuotaMetrics.isEmpty)
    store.setClaudeEnabled(false)
    store.setClaudeEnabled(true)
    #expect(!store.isRefreshingClaude)
    #expect(store.claudeError == .rateLimited)
}

@Test func claudeRetryAfterAcceptsSecondsAndHTTPDate() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(DirectClaudeUsageReader.retryDate("120", now: now) == now.addingTimeInterval(120))
    #expect(DirectClaudeUsageReader.retryDate("Thu, 01 Jan 1970 01:00:00 GMT", now: now) == now.addingTimeInterval(3600))
    for value in ["0", "-1", "NaN", "invalid"] { #expect(DirectClaudeUsageReader.retryDate(value, now: now) == nil) }
}

@Test func touchBarHandlesProviderMetricWithoutResetDate() {
    let content = TouchBarQuotaContent(label: "CL 5小时", metric: .init(id: "5h", window: "5h", remainingPercent: 60, resetsAt: nil),
                                      status: .live, includesDate: false)
    #expect(content.title == "CL 5小时 60%")
    #expect(content.detail == "未提供重置时间")
    #expect(content.remainingFraction == 0.6)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_LIVE_CHECK"] == "1"))
func readsLocalClaudeQuotaWithoutPrintingCredentials() async throws {
    let result = try await DirectClaudeUsageReader().read()
    #expect(!result.metrics.isEmpty)
    print("Claude quota read succeeded: \(result.planName), \(result.metrics.count) windows")
}

@Test @MainActor func touchBarFollowsMenuSelectionAndRotationIncludingClaude() async throws {
    _ = NSApplication.shared
    let name = "touchbar-sources-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "antigravityEnabled")
    defaults.set(true, forKey: "claudeEnabled")
    let model = UsageModel(defaults: defaults)
    model.useManualValues(fiveHour: .init(name: "", budget: 100, used: 10, resetsAt: .now),
                          weekly: .init(name: "", budget: 100, used: 20, resetsAt: .now))
    let store = ProviderStore(codex: model, defaults: defaults, readAntigravity: { _ in
        .init(installation: .init(path: "/test/agy", version: "1.3.2"), groups: try AntigravityReport.parse(antigravityFixture))
    }, readClaude: { _ in
        .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max")
    })
    defer { store.stop() }
    let controller = MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
    let bar = try #require(controller.touchBar)
    let chart = try #require((bar.item(forIdentifier: .init("codex.quota.fiveHour")) as? NSCustomTouchBarItem)?.view as? TouchBarQuotaChartView)
    let cat = try #require((bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)?.view as? TouchBarRainbowCatView)
    store.onChange = { controller.updateQuotaTouchBar() }
    store.refreshAntigravity()
    store.refreshClaude()
    try await settleClaude(store)
    for _ in 0..<200 where store.isRefreshingAntigravity { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.claude)
    #expect(chart.content?.title == "CL 5小时 73%")
    #expect(chart.content?.remainingFraction == 0.725)
    #expect(cat.activity == .sleepy)
    store.setMenuSource(.antigravityThirdParty)
    #expect(chart.content?.title == "C+G 5小时 0%")
    store.setMenuSource(.codex)
    #expect(chart.content?.title == "5小时 90%（手动）")
    #expect(cat.activity == .energetic)
    store.setMenuRotationInterval(5, now: 0)
    store.setMenuRotationEnabled(true, now: 0)
    store.advanceMenuRotation(now: 5)
    #expect(chart.content?.title == "G 5小时 100%")
    store.advanceMenuRotation(now: 10)
    store.advanceMenuRotation(now: 15)
    #expect(store.displayedMenuSource == .claude)
    #expect(chart.content?.title == "CL 5小时 73%")
    let refresh = try #require(bar.item(forIdentifier: .init("codex.quota.refresh")) as? NSButtonTouchBarItem)
    let codexAttempt = model.lastRefreshAt
    let agAttempt = store.antigravityLastAttemptAt
    #expect(NSApp.sendAction(try #require(refresh.action), to: refresh.target, from: nil))
    #expect(store.isRefreshingClaude)
    #expect(chart.content?.title == "CL 5小时 —")
    #expect(cat.activity == .sleeping)
    #expect(!refresh.isEnabled)
    #expect(model.lastRefreshAt == codexAttempt)
    #expect(store.antigravityLastAttemptAt == agAttempt)
    try await settleClaude(store)
    store.setClaudeEnabled(false)
    #expect(chart.content?.title == "5小时 90%（手动）")
    store.setCodexEnabled(false)
    store.setAntigravityEnabled(false)
    #expect(chart.content?.remainingFraction == nil)
    #expect(!refresh.isEnabled)
    #expect(cat.activity == .sleeping)
}
