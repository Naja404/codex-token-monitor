import AppKit
import Foundation
import Testing
@testable import CodexTokenMonitor

let warpFixture = #"{"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":false,"requestLimit":1500,"requestsUsedSinceLastRefresh":600,"nextRefreshTime":"2026-11-01T00:00:00Z"},"bonusGrants":[{"requestCreditsGranted":200,"requestCreditsRemaining":150,"expiration":"2099-12-01T00:00:00Z"}],"workspaces":[{"bonusGrantsInfo":{"grants":[{"requestCreditsGranted":999,"requestCreditsRemaining":999}]}}]}}}}"#

@Test func warpReportsCreditsWithoutMixingWorkspacePools() throws {
    let value = try WarpUsageSnapshot.parse(Data(warpFixture.utf8))
    #expect(value.remaining == 900)
    #expect(value.metric?.remainingPercent == 60)
    #expect(value.metric?.window == "cycle")
    #expect(value.resetsAt != nil)
    #expect(value.bonusRemaining == 150)
}

@Test @MainActor func warpCooldownSurvivesToggleAndCredentialChanges() async throws {
    let name = "warp-cooldown-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let retry = Date().addingTimeInterval(7200)
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readWarp: { _ in
        throw WarpUsageFailure(reason: .rateLimited, retryAt: retry)
    })
    defer { store.stop() }
    store.setWarpEnabled(true)
    for _ in 0..<200 where store.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.warp)
    #expect(store.nextWarpRefresh == retry)
    #expect(!store.canRefreshDisplayedSource)
    store.warpCredentialChanged()
    store.refreshWarp(allowInteraction: true)
    #expect(!store.isRefreshingWarp)
    store.setWarpEnabled(false)
    store.setWarpEnabled(true)
    #expect(!store.isRefreshingWarp)
    #expect(store.warpError == .rateLimited)
}

@Test @MainActor func warpIgnoresLateResultAndPausesOnAuthFailure() async throws {
    let name = "warp-cancel-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readWarp: { _ in
        try? await Task.sleep(for: .milliseconds(30))
        return try WarpUsageSnapshot.parse(Data(warpFixture.utf8))
    })
    defer { store.stop() }
    store.setWarpEnabled(true)
    store.setWarpEnabled(false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.warpSnapshot == nil)
    #expect(store.warpLastSuccessAt == nil)
    let failed = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readWarp: { _ in
        throw WarpReadError.unauthorized
    })
    defer { failed.stop() }
    failed.setWarpEnabled(true)
    for _ in 0..<200 where failed.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    failed.tick(now: .distantFuture)
    #expect(failed.warpError == .unauthorized)
    #expect(!failed.isRefreshingWarp)
    #expect(failed.warpSnapshot == nil)
}

@Test @MainActor func warpTouchBarShowsCreditsAndCatUsesCyclePercentage() async throws {
    _ = NSApplication.shared
    let name = "warp-touchbar-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults, readWarp: { _ in
        try WarpUsageSnapshot.parse(Data(warpFixture.utf8))
    })
    defer { store.stop() }
    store.setWarpEnabled(true)
    for _ in 0..<200 where store.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.warp)
    let controller = MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
    let bar = try #require(controller.touchBar)
    let chart = try #require((bar.item(forIdentifier: .init("codex.quota.fiveHour")) as? NSCustomTouchBarItem)?.view as? TouchBarQuotaChartView)
    let bonus = try #require((bar.item(forIdentifier: .init("codex.quota.weekly")) as? NSCustomTouchBarItem)?.view as? TouchBarQuotaChartView)
    let cat = try #require((bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)?.view as? TouchBarRainbowCatView)
    controller.updateQuotaTouchBar()
    #expect(chart.content?.title == "W 900 Credits")
    #expect(chart.content?.remainingFraction == 0.6)
    #expect(bonus.content?.title == "额外 150 Credits")
    #expect(bonus.content?.remainingFraction == nil)
    #expect(cat.activity == .playful)
}

@Test func warpExpiredBonusIsExcludedAndOveruseClampsToZero() throws {
    let expired = warpFixture.replacingOccurrences(of: "2099-12-01", with: "2000-12-01")
        .replacingOccurrences(of: "\"requestsUsedSinceLastRefresh\":600", with: "\"requestsUsedSinceLastRefresh\":2000")
    let result = try WarpUsageSnapshot.parse(Data(expired.utf8))
    #expect(result.remaining == 0)
    #expect(result.metric?.remainingPercent == 0)
    #expect(result.bonusRemaining == 0)
}

@Test func warpUnlimitedAndZeroDoNotInventPercentages() throws {
    let unlimited = try WarpUsageSnapshot.parse(Data(warpFixture.replacingOccurrences(of: "\"isUnlimited\":false", with: "\"isUnlimited\":true").utf8))
    #expect(unlimited.metric == nil)
    #expect(unlimited.balanceText == "无上限")
    let zero = try WarpUsageSnapshot.parse(Data(warpFixture.replacingOccurrences(of: "\"requestLimit\":1500", with: "\"requestLimit\":0").utf8))
    #expect(zero.metric == nil)
    #expect(zero.remaining == 0)
}

@Test(arguments: ["{}", "{\"errors\":[{\"message\":\"secret\"}]}",
                  warpFixture.replacingOccurrences(of: "1500", with: "true"),
                  warpFixture.replacingOccurrences(of: "1500", with: "-1")])
func warpRejectsMalformedResponse(_ json: String) {
    #expect(throws: WarpReadError.invalidResponse) { try WarpUsageSnapshot.parse(Data(json.utf8)) }
}

@Test func warpRequestUsesFixedOfficialEndpointAndReadOnlyQuery() throws {
    let request = try WarpUsageReader.request(key: "wk-test")
    #expect(request.url?.host == "app.warp.dev")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wk-test")
    let body = try #require(String(data: request.httpBody!, encoding: .utf8))
    #expect(body.contains("GetRequestLimitInfo"))
    #expect(!body.contains("mutation"))
    #expect(!body.contains("workspaces"))
    #expect(throws: WarpReadError.missingKey) { try WarpUsageReader.request(key: "") }
    #expect(throws: WarpReadError.missingKey) { try WarpUsageReader.request(key: "wk-test\nheader") }
}

@Test @MainActor func warpOptInVerificationAndPopoverMode() async throws {
    let name = "warp-test-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults,
                              readWarp: { _ in try WarpUsageSnapshot.parse(Data(warpFixture.utf8)) })
    defer { store.stop() }
    #expect(!store.warpEnabled)
    #expect(store.popoverMode == .summary)
    store.popoverMode = .details
    store.beginPopover()
    #expect(store.popoverMode == .summary)
    store.refreshWarp()
    for _ in 0..<200 where store.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.warpSnapshot?.remaining == 900)
    #expect(!store.warpEnabled)
    store.setWarpEnabled(true)
    for _ in 0..<200 where store.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    store.setMenuSource(.warp)
    #expect(store.displayedQuotaMetrics.first?.remainingPercent == 60)
    #expect(store.menuLines.first.contains("900"))
    #expect(!store.menuLines.first.contains("5小时"))
    #expect(store.nextWarpRefresh.timeIntervalSinceNow > 290)
    store.setWarpEnabled(false)
    #expect(store.warpSnapshot == nil)
    #expect(!store.availableMenuSources.contains(.warp))
}
