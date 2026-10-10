import AppKit
import Foundation
import Testing
@testable import CodexTokenMonitor

let teamoBalanceFixture = Data(#"{"balance":{"value":"85.320000","currency":"USD"}}"#.utf8)
let teamoCostsFixture = Data(#"{"start_time":100,"end_time":200,"total_amount":{"value":"1.280000","currency":"USD"},"requests":86}"#.utf8)
let teamoTokensFixture = Data(#"{"start_time":100,"end_time":200,"usage":{"input_tokens":120000,"output_tokens":30000,"cached_write_tokens":10000,"cached_read_tokens":80000,"total_tokens":240000},"requests":86}"#.utf8)

func teamoFixture() throws -> TeamoUsageSnapshot {
    try .parse(balance: teamoBalanceFixture, costs: teamoCostsFixture, usage: teamoTokensFixture,
               start: 100, end: 200)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TEAMO_LIVE_CHECK"] == "1"))
func teamoLiveReadFromZshrc() async throws {
    do {
        let config = try TeamoConfiguration.importZshrc()
        let snapshot = try await TeamoUsageReader().read(configuration: config)
        // Never print configuration, requests, response bodies, or credentials.
        print("TeamoRouter live verification: balance=\(snapshot.balanceText), today cost=\(snapshot.costText), tokens=\(snapshot.totalTokens), requests=\(snapshot.requests)")
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalTokens >= 0)
    } catch {
        let reason = (error as? TeamoUsageFailure)?.reason ?? error as? TeamoReadError ?? .network
        Issue.record("TeamoRouter live verification failed: \(reason.localizedDescription)")
    }
}

@Test func teamoImportsLiteralClaudeEnvironmentWithoutExecutingShell() throws {
    let config = try TeamoConfiguration.parseZshrc("""
    # export ANTHROPIC_AUTH_TOKEN=ignore
    export ANTHROPIC_BASE_URL="https://api.teamorouter.com" # comment
    export ANTHROPIC_AUTH_TOKEN='test-key'
    echo ignored
    """)
    #expect(config.baseURL == "https://api.teamorouter.com")
    #expect(config.token == "test-key")
    #expect(try TeamoConfiguration.environment([
        "ANTHROPIC_BASE_URL": config.baseURL, "ANTHROPIC_AUTH_TOKEN": config.token
    ])?.baseURL == config.baseURL)
    #expect(try TeamoConfiguration.environment([:]) == nil)
}

@Test(arguments: ["$(echo secret)", "$OTHER_KEY", "`echo secret`", "abc; echo unsafe", "abc && echo unsafe", "'unterminated"])
func teamoRejectsDynamicShellValues(_ value: String) {
    #expect(throws: TeamoReadError.importUnsupported) {
        try TeamoConfiguration.parseZshrc("export ANTHROPIC_BASE_URL=https://api.teamorouter.com\nexport ANTHROPIC_AUTH_TOKEN=\(value)")
    }
}

@Test func teamoRejectsConditionalAssignmentsAndUnknownDestinations() {
    #expect(throws: TeamoReadError.importUnsupported) {
        try TeamoConfiguration.parseZshrc("if false; then\nexport ANTHROPIC_AUTH_TOKEN=wrong\nfi\nexport ANTHROPIC_BASE_URL=https://api.teamorouter.com")
    }
    for url in ["http://api.teamorouter.com", "https://evil.example", "https://api.teamorouter.com.evil.example", "https://user@api.teamorouter.com", "https://api.teamorouter.com/v1", "https://api.teamorouter.com?x=secret"] {
        #expect(throws: TeamoReadError.invalidConfiguration) { try TeamoConfiguration(baseURL: url, token: "test-key") }
    }
    #expect(throws: TeamoReadError.invalidConfiguration) {
        try TeamoConfiguration(baseURL: "https://api.teamorouter.com", token: "test\r\nkey")
    }
}

@Test(arguments: ["if false; then", "f() {", "(", "{"])
func teamoRejectsAssignmentsInsideShellBlocks(_ opener: String) {
    #expect(throws: TeamoReadError.importUnsupported) {
        try TeamoConfiguration.parseZshrc("\(opener)\nexport ANTHROPIC_BASE_URL=https://api.teamorouter.com\nexport ANTHROPIC_AUTH_TOKEN=test-key")
    }
}

@Test func teamoRejectsMissingAndMalformedDataButAcceptsZeroAndDebt() throws {
    for text in ["{}", #"{"balance":{"value":"NaN","currency":"USD"}}"#,
                 #"{"balance":{"value":"1oops","currency":"USD"}}"#,
                 #"{"balance":{"value":"1","currency":"EUR"}}"#] {
        #expect(throws: TeamoReadError.invalidResponse) {
            try TeamoUsageSnapshot.parse(balance: Data(text.utf8), costs: teamoCostsFixture,
                                         usage: teamoTokensFixture, start: 100, end: 200)
        }
    }
    for value in ["0", "-0.05"] {
        let result = try TeamoUsageSnapshot.parse(balance: Data("{\"balance\":{\"value\":\"\(value)\",\"currency\":\"USD\"}}".utf8),
            costs: teamoCostsFixture, usage: teamoTokensFixture, start: 100, end: 200)
        #expect(result.balance == Decimal(string: value))
    }
    for replacement in ["true", "-1", "1.5"] {
        let usage = String(data: teamoTokensFixture, encoding: .utf8)!.replacingOccurrences(of: "240000", with: replacement)
        #expect(throws: TeamoReadError.invalidResponse) {
            try TeamoUsageSnapshot.parse(balance: teamoBalanceFixture, costs: teamoCostsFixture,
                                         usage: Data(usage.utf8), start: 100, end: 200)
        }
    }
}

@Test @MainActor func teamoCooldownSurvivesCredentialChangesAndToggles() async throws {
    let name = "teamo-cooldown-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let retry = Date().addingTimeInterval(7200)
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readTeamo: { _ in
        throw TeamoUsageFailure(reason: .rateLimited, retryAt: retry)
    })
    defer { store.stop() }
    store.setTeamoEnabled(true)
    for _ in 0..<200 where store.isRefreshingTeamo { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.teamo)
    #expect(store.nextTeamoRefresh == retry)
    #expect(!store.canRefreshDisplayedSource)
    store.teamoCredentialChanged()
    store.setTeamoEnabled(false)
    store.setTeamoEnabled(true)
    store.refreshTeamo(allowInteraction: true)
    #expect(!store.isRefreshingTeamo)
    #expect(store.teamoError == .rateLimited)
}

@Test @MainActor func teamoIgnoresLateResultsAndAuthFailuresStopPolling() async throws {
    let name = "teamo-late-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readTeamo: { _ in
        try? await Task.sleep(for: .milliseconds(30))
        return try teamoFixture()
    })
    defer { store.stop() }
    store.setTeamoEnabled(true)
    store.setTeamoEnabled(false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.teamoSnapshot == nil)
    #expect(store.teamoLastSuccessAt == nil)
    let failed = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readTeamo: { _ in
        throw TeamoReadError.unauthorized
    })
    defer { failed.stop() }
    failed.setTeamoEnabled(true)
    for _ in 0..<200 where failed.isRefreshingTeamo { try await Task.sleep(for: .milliseconds(5)) }
    failed.tick(now: .distantFuture)
    failed.setMenuSource(.teamo)
    #expect(failed.teamoError == .unauthorized)
    #expect(!failed.isRefreshingTeamo)
    #expect(failed.menuLines.first.contains("—"))
    #expect(failed.displayedQuotaMetrics.isEmpty)
}

@Test func teamoParsesMoneyAndUsageWithoutInventingRemainingTokens() throws {
    let value = try teamoFixture()
    #expect(value.balance == Decimal(string: "85.32"))
    #expect(value.cost == Decimal(string: "1.28"))
    #expect(value.totalTokens == 240000)
    #expect(value.requests == 86)
    #expect(value.currency == "USD")
    #expect(throws: TeamoReadError.invalidResponse) {
        try TeamoUsageSnapshot.parse(balance: Data("{}".utf8), costs: teamoCostsFixture,
                                     usage: teamoTokensFixture, start: 100, end: 200)
    }
    #expect(throws: TeamoReadError.invalidResponse) {
        try TeamoUsageSnapshot.parse(balance: teamoBalanceFixture, costs: teamoCostsFixture,
                                     usage: teamoTokensFixture, start: 101, end: 200)
    }
}

@Test func teamoRequestIsReadOnlyAndUsesSameTimeWindow() throws {
    let config = try TeamoConfiguration(baseURL: "https://api.teamorouter.com/", token: "test-key")
    let request = try TeamoUsageReader.request(config, path: "/v1/usage", start: 100, end: 200)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.url?.absoluteString == "https://api.teamorouter.com/v1/usage?start_time=100&end_time=200")
    #expect(request.httpBody == nil)
}

@Test @MainActor func teamoVerificationDoesNotEnablePollingAndShowsMoneyNotPercent() async throws {
    _ = NSApplication.shared
    let name = "teamo-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults, readTeamo: { _ in try teamoFixture() })
    defer { store.stop() }
    #expect(!store.teamoEnabled)
    store.refreshTeamo()
    for _ in 0..<200 where store.isRefreshingTeamo { try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.teamoSnapshot?.totalTokens == 240000)
    #expect(!store.teamoEnabled)
    store.setTeamoEnabled(true)
    for _ in 0..<200 where store.isRefreshingTeamo { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.teamo)
    #expect(store.displayedQuotaMetrics.isEmpty)
    #expect(store.menuLines.first.contains("85.32"))
    #expect(!store.menuLines.first.contains("%"))
    #expect(store.nextTeamoRefresh.timeIntervalSinceNow > 290)
    let controller = MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
    let bar = try #require(controller.touchBar)
    controller.updateQuotaTouchBar()
    let cat = try #require((bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)?.view as? TouchBarRainbowCatView)
    #expect(cat.activity == .sleeping)
    store.setTeamoEnabled(false)
    #expect(store.teamoSnapshot == nil)
}
