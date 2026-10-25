import Foundation
import Testing
@testable import CodexTokenMonitor

// Hold each response until the test releases it, including errors and identical data.
private actor MenuReadGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, any Error>?
    func read() async throws -> Value {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func respond(_ result: Result<Value, any Error>) async {
        while pending == nil { await Task.yield() }
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor private func menuDefaults() -> UserDefaults {
    UserDefaults(suiteName: "menu-refresh-\(UUID())")!
}

@MainActor private func settle(_ ready: () -> Bool) async throws {
    for _ in 0..<200 {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Menu refresh did not settle")
}

// Shape and IDs verified against agy 1.4.7; values are synthetic.
let antigravityArgonFixture = """
{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9}]},
{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.44,"reset_time":"2026-10-25T11:04:39Z"}]},
{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.6}]}
]}}}
"""

@Test func argonPoolHasIndependentStableIdentityAndOnlyReportedWindows() throws {
    let groups = try AntigravityReport.parse(antigravityArgonFixture)
    #expect(groups.map(\.id) == ["gemini", "gemini-argon", "3p"])
    #expect(Set(groups.map(\.id)).count == 3)
    #expect(groups[1].metrics.map(\.window) == ["weekly"])
    #expect(groups[1].metrics.first?.remainingPercent == 44)
    let reversed = antigravityArgonFixture.replacingOccurrences(of: "Gemini Models", with: "Gemini Pro and Flash")
    #expect(try AntigravityReport.parse(reversed).map(\.id) == groups.map(\.id))
}

@Test @MainActor func codexMenuKeepsDataUntilSuccessfulReplacementAndClearsOnDisable() async throws {
    let defaults = menuDefaults()
    let gate = MenuReadGate<LiveRateLimits>()
    let model = UsageModel(defaults: defaults, readUsage: { try await gate.read() })
    let store = ProviderStore(codex: model, defaults: defaults)
    defer { store.stop() }
    let limits = LiveRateLimits(primary: .init(usedPercent: 20, resetsAt: 1_800_000_000),
                                secondary: .init(usedPercent: 40, resetsAt: 1_800_600_000), planName: "Pro", additional: [])
    model.refresh()
    #expect(store.menuLines.first.contains("—"))
    await gate.respond(.success(limits))
    try await settle { model.rateLimitStatus == .live }
    let menu = store.menuLines
    #expect(menu.first.contains("80%"))
    model.refresh()
    #expect(store.menuLines == menu)
    await gate.respond(.success(limits))
    try await settle { model.rateLimitStatus == .live }
    #expect(store.menuLines == menu)
    model.refresh()
    #expect(store.menuLines == menu)
    await gate.respond(.failure(ProviderReadError.network))
    try await settle { model.rateLimitStatus == .unavailable }
    #expect(store.menuLines == menu)
    #expect(model.readError == .network)
    #expect(model.fiveHour == nil) // Old menu data must not be used as live data or written back.
    model.refresh()
    await gate.respond(.success(.init(primary: .init(usedPercent: 100, resetsAt: 1_800_000_000),
                                     secondary: nil, planName: "Pro", additional: [])))
    try await settle { model.rateLimitStatus == .live }
    #expect(store.menuLines.first.contains("0%"))
    #expect(store.menuLines.second.contains("—"))
    store.setCodexEnabled(false)
    #expect(model.menuMetrics.isEmpty)
}

@Test @MainActor func argonMenuSurvivesRefreshAndRotationAndClearsOnConnectionChange() async throws {
    let defaults = menuDefaults()
    defaults.set(true, forKey: "antigravityEnabled")
    let gate = MenuReadGate<AntigravitySnapshot>()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readAntigravity: { _ in try await gate.read() })
    defer { store.stop() }
    #expect(!store.availableMenuSources.contains(.antigravityArgon))
    let snapshot = AntigravitySnapshot(installation: .init(path: "/test/agy", version: "1.4.7"),
                                       groups: try AntigravityReport.parse(antigravityArgonFixture))
    store.refreshAntigravity()
    await gate.respond(.success(snapshot))
    try await settle { !store.isRefreshingAntigravity }
    #expect(store.availableMenuSources.contains(.antigravityArgon))
    store.setMenuSource(.antigravityArgon)
    let menu = store.menuLines
    #expect(menu.first == "G4 Argon")
    #expect(menu.second.contains("44%"))
    #expect(store.displayedQuotaMetrics.map(\.window) == ["weekly"])
    store.refreshAntigravity()
    #expect(store.menuLines == menu)
    store.setMenuSource(.antigravityGemini)
    #expect(store.menuLines.second.contains("90%"))
    store.setMenuSource(.antigravityArgon)
    #expect(store.menuLines == menu)
    await gate.respond(.failure(ProviderReadError.network))
    try await settle { !store.isRefreshingAntigravity }
    #expect(store.menuLines == menu)
    #expect(store.antigravityError == .network)
    store.saveCLIPath("/test/changed-agy")
    #expect(store.menuLines.second.contains("—"))
    await gate.respond(.success(snapshot))
    try await settle { !store.isRefreshingAntigravity }
    store.setAntigravityEnabled(false)
    #expect(!store.availableMenuSources.contains(.antigravityArgon))
}

@Test @MainActor func claudeMenuRetainsSuccessfulQuotaDuringRefreshAndFailure() async throws {
    let defaults = menuDefaults()
    defaults.set(true, forKey: "claudeEnabled")
    let gate = MenuReadGate<ClaudeUsageSnapshot>()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readClaude: { _ in try await gate.read() })
    defer { store.stop() }
    store.setMenuSource(.claude)
    store.refreshClaude()
    await gate.respond(.success(.init(metrics: [.init(id: "5h", window: "5h", remainingPercent: 50, resetsAt: nil)], planName: "Pro")))
    try await settle { !store.isRefreshingClaude }
    let menu = store.menuLines
    store.refreshClaude()
    #expect(store.menuLines == menu)
    await gate.respond(.failure(ProviderReadError.network))
    try await settle { !store.isRefreshingClaude }
    #expect(store.menuLines == menu)
    #expect(store.claudeMetrics.isEmpty)
    store.setClaudeEnabled(false)
    store.setClaudeEnabled(true)
    store.setMenuSource(.claude)
    #expect(store.menuLines.first.contains("—"))
    await gate.respond(.failure(ProviderReadError.network))
    try await settle { !store.isRefreshingClaude }
}

@Test @MainActor func warpMenuRetainsCreditsAndClearsWhenKeyChanges() async throws {
    let defaults = menuDefaults()
    defaults.set(true, forKey: "warpEnabled")
    let gate = MenuReadGate<WarpUsageSnapshot>()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readWarp: { _ in try await gate.read() })
    defer { store.stop() }
    store.setMenuSource(.warp)
    store.refreshWarp()
    await gate.respond(.success(.init(limit: 100, used: 30, unlimited: false, resetsAt: nil, bonusRemaining: nil)))
    try await settle { !store.isRefreshingWarp }
    let menu = store.menuLines
    store.refreshWarp()
    #expect(store.menuLines == menu)
    await gate.respond(.failure(WarpReadError.network))
    try await settle { !store.isRefreshingWarp }
    #expect(store.menuLines == menu)
    store.warpCredentialChanged()
    #expect(store.menuLines.first.contains("—"))
}

@Test @MainActor func teamoMenuRetainsMoneyAndClearsWhenKeyChanges() async throws {
    let defaults = menuDefaults()
    defaults.set(true, forKey: "teamoEnabled")
    let gate = MenuReadGate<TeamoUsageSnapshot>()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readTeamo: { _ in try await gate.read() })
    defer { store.stop() }
    store.setMenuSource(.teamo)
    store.refreshTeamo()
    await gate.respond(.success(.init(balance: 30, cost: 1, currency: "USD", totalTokens: 100, requests: 1, start: 1, end: 2)))
    try await settle { !store.isRefreshingTeamo }
    let menu = store.menuLines
    store.refreshTeamo()
    #expect(store.menuLines == menu)
    await gate.respond(.failure(TeamoReadError.network))
    try await settle { !store.isRefreshingTeamo }
    #expect(store.menuLines == menu)
    store.teamoCredentialChanged()
    #expect(store.menuLines.first.contains("—"))
}
