import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import CodexTokenMonitor

private let resetDetailsFixture = """
{"available_count":2,"credits":[
 {"id":"later","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":true,"expires_at":"2027-01-12T22:26:04.659420Z"},
 {"id":"first","reset_type":"codex_rate_limits","status":"available","expires_at":"2027-01-01T22:29:53Z"},
 {"id":"used","reset_type":"codex_rate_limits","status":"redeemed","expires_at":null},
 {"id":"unsupported","reset_type":"codex_rate_limits","status":"available","is_supported_by_plan":false,"expires_at":null},
 {"id":"other","reset_type":"future_type","status":"available","expires_at":null}
]}
"""

@Test func resetCreditsDecodeSummaryAndFilterUsableDetails() throws {
    let summary = try JSONDecoder().decode(CodexResetCredits.self, from: Data(
        #"{"available_count":3,"applicable_available_count":2}"#.utf8))
    #expect(summary.availableCount == 2)
    #expect(summary.credits == nil)
    let details = try JSONDecoder().decode(CodexResetCredits.self, from: Data(resetDetailsFixture.utf8))
    #expect(details.availableCount == 2)
    #expect(details.credits?.map(\.id) == ["first", "later"])
    #expect(details.credits?.allSatisfy { $0.expiresAt != nil } == true)
    let unknownExpiry = try JSONDecoder().decode(CodexResetCredit.self, from: Data(
        #"{"id":"no-expiry","reset_type":"codex_rate_limits","status":"available","expires_at":null}"#.utf8))
    #expect(unknownExpiry.expiresAt == nil)
    #expect(unknownExpiry.expiryKnown)
    let missingExpiry = try JSONDecoder().decode(CodexResetCredit.self, from: Data(
        #"{"id":"missing","reset_type":"codex_rate_limits","status":"available"}"#.utf8))
    #expect(!missingExpiry.expiryKnown)
}

@Test func malformedResetFeatureCannotBreakExistingQuota() throws {
    for value in [#"{"available_count":-1}"#, #"{"available_count":"invalid"}"#, "null"] {
        let data = Data("{\"plan_type\":\"pro\",\"rate_limit_reset_credits\":\(value)}".utf8)
        let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)
        #expect(payload.liveRateLimits?.planName == "Pro")
        #expect(payload.resetCredits == nil)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CodexResetCredit.self, from: Data(
            #"{"id":"bad","reset_type":"codex_rate_limits","status":"available","expires_at":"bad-date"}"#.utf8))
    }
}

private final class ResetReadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let mode = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let valid = request.httpMethod == "GET" && request.value(forHTTPHeaderField: "chatgpt-account-id") == "fixture"
        let isDetails = path == "/backend-api/wham/rate-limit-reset-credits"
        let code = !valid ? 400 : (isDetails && mode.contains("failure") ? 503 : 200)
        let body = isDetails ? resetDetailsFixture : """
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000,"reset_at":1900000000}},"rate_limit_reset_credits":{"available_count":2}}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: [false, true])
func resetDetailReadIsOptionalAndUsesOnlyGET(detailsFail: Bool) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("reset-auth-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{\"tokens\":{\"access_token\":\"\(detailsFail ? "failure" : "success")\",\"account_id\":\"fixture\"}}".utf8).write(to: url)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResetReadProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let result = try await DirectCodexUsageReader(session: session, credentialsURL: url).read()
    #expect(result.primary?.usedPercent == 30)
    #expect(result.resetCredits?.availableCount == 2)
    #expect(result.resetCredits?.credits?.count == (detailsFail ? nil : 2))
    #expect(result.accountID == "fixture")
}

private actor ResetSnapshotReader {
    var values: [LiveRateLimits?]
    init(_ values: [LiveRateLimits?]) { self.values = values }
    func read() throws -> LiveRateLimits {
        guard let value = values.removeFirst() else { throw ProviderReadError.network }
        return value
    }
}

@MainActor private func refreshResetModel(_ model: UsageModel) async throws {
    model.refresh()
    for _ in 0..<200 where model.rateLimitStatus == .loading { try await Task.sleep(for: .milliseconds(2)) }
    #expect(model.rateLimitStatus != .loading)
    // The model releases the task after publishing its completed state.
    await Task.yield()
}

@Test @MainActor func resetSnapshotPreservesOldValuesWithoutTreatingThemAsFreshAndClearsOnAccountChange() async throws {
    let suite = "reset-cache-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = CodexResetCredits(availableCount: 1, credits: [.init(id: "one", expiresAt: .now.addingTimeInterval(86400))])
    func limits(_ snapshot: CodexResetCredits?, account: String = "a") -> LiveRateLimits {
        .init(primary: nil, secondary: nil, planName: "Pro", additional: [], resetCredits: snapshot, accountID: account)
    }
    let reader = ResetSnapshotReader([limits(snapshot), limits(snapshot), limits(.init(availableCount: 1)),
                                      nil, limits(nil), limits(nil, account: "b"), limits(snapshot)])
    let model = UsageModel(defaults: defaults, readUsage: { try await reader.read() })
    let store = ProviderStore(codex: model, defaults: defaults)
    defer { store.stop() }
    var publications = 0
    let subscription = model.$resetCredits.sink { _ in publications += 1 }
    defer { subscription.cancel() }
    try await refreshResetModel(model)
    #expect(model.resetCredits == snapshot)
    #expect(model.resetCreditDetailsCurrent)
    #expect(store.localNotificationObservations.contains { $0.source == "codexResetCredits" })
    let count = publications
    try await refreshResetModel(model)
    #expect(publications == count)
    try await refreshResetModel(model)
    #expect(model.resetCredits == snapshot)
    #expect(model.resetCreditsCurrent && !model.resetCreditDetailsCurrent)
    #expect(!store.localNotificationObservations.contains { $0.source == "codexResetCredits" })
    try await refreshResetModel(model)
    #expect(model.resetCredits == snapshot && !model.resetCreditsCurrent)
    try await refreshResetModel(model)
    #expect(model.resetCredits == snapshot && !model.resetCreditsCurrent)
    try await refreshResetModel(model)
    #expect(model.resetCredits == nil)
    try await refreshResetModel(model)
    model.setMonitoringEnabled(false)
    #expect(model.resetCredits == nil)
}

@Test func resetExpiryAlertsAreOptInFreshDeduplicatedAndRetryable() throws {
    let now = Date(timeIntervalSince1970: 1800000000)
    let credits: [CodexResetCredit] = [
        .init(id: "soon", expiresAt: now.addingTimeInterval(86400)),
        .init(id: "edge", expiresAt: now.addingTimeInterval(3 * 86400)),
        .init(id: "later", expiresAt: now.addingTimeInterval(4 * 86400)),
        .init(id: "expired", expiresAt: now), .init(id: "no-expiry", expiresAt: nil)]
    func observation(_ sample: String) -> NotificationObservation {
        .init(source: "codexResetCredits", title: "Codex", sample: sample, result: .resetCredits(credits))
    }
    var p = LocalNotificationPreferences(), policy = LocalNotificationPolicy()
    #expect(!p.kinds.contains(.resetCreditExpiry))
    p.enabled = true
    #expect(policy.evaluate(observation("one"), preferences: p, now: now).isEmpty)
    let old = p; p.kinds.insert(.resetCreditExpiry)
    policy.preferencesChanged(from: old, to: p)
    let alerts = policy.evaluate(observation("one"), preferences: p, now: now)
    #expect(alerts.count == 1)
    #expect(alerts.first?.levelIDs == ["soon", "edge"])
    #expect(policy.evaluate(observation("two"), preferences: p, now: now).isEmpty)
    policy = try JSONDecoder().decode(LocalNotificationPolicy.self, from: JSONEncoder().encode(policy))
    #expect(policy.evaluate(observation("three"), preferences: p, now: now).isEmpty)
    let next = policy.evaluate(observation("four"), preferences: p, now: now.addingTimeInterval(86400))
    #expect(next.first?.levelIDs == ["later"])
    policy.deliveryFailed(try #require(next.first))
    #expect(policy.evaluate(observation("four"), preferences: p, now: now.addingTimeInterval(86400)).count == 1)
    let persisted = Data(#"{"states":{"codex":{"lastSample":"x","low":[],"announcedLow":[],"failures":0,"announcedFailure":true,"announcedSignIn":false}}}"#.utf8)
    #expect(try JSONDecoder().decode(LocalNotificationPolicy.self, from: persisted).states["codex"]?.announcedFailure == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_RESET_LIVE_TEST"] == "1"))
func readsActualCodexResetCreditsWithoutRedeeming() async throws {
    let value = try await DirectCodexUsageReader().read()
    #expect(value.resetCredits != nil)
    #expect(value.resetCredits?.credits != nil)
    #expect((value.resetCredits?.availableCount ?? -1) >= 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RESET_PREVIEW_DIR"] != nil))
@MainActor func rendersResetCreditCardsAndOptionalNotificationSettings() async throws {
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RESET_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let suite = "reset-preview-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = try JSONDecoder().decode(CodexResetCredits.self, from: Data(resetDetailsFixture.utf8))
    let model = UsageModel(defaults: defaults, readUsage: {
        .init(primary: .init(usedPercent: 24, resetsAt: 1900000000), secondary: .init(usedPercent: 48, resetsAt: 1900300000),
              planName: "Pro", additional: [], resetCredits: snapshot)
    })
    try await refreshResetModel(model)
    let store = ProviderStore(codex: model, defaults: defaults)
    defer { store.stop() }
    store.appearance.motion = .off
    for mode in [MonitorColorMode.light, .dark] {
        store.appearance.mode = mode
        store.beginPopover()
        for expanded in [false, true] {
            if expanded { store.toggleProviderDetails(.codex) }
            let host = NSHostingView(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
            host.setFrameSize(.init(width: 360, height: 540))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("resets-\(mode.rawValue)-\(expanded).png"))
            if expanded { store.toggleProviderDetails(.codex) }
        }
    }
}
