import Foundation
import Testing
@testable import CodexTokenMonitor

@Test func releaseVersionsCompareNumericallyAndRespectPrereleaseOrder() throws {
    let ordered = ["1.4.7-alpha", "1.4.7-alpha.2", "1.4.7-alpha.10", "1.4.7-beta", "1.4.7-rc.1", "1.4.7", "1.4.10", "1.10.0", "2.0.0"]
    let versions = try ordered.map { try #require(ReleaseVersion($0)) }
    #expect(versions.sorted() == versions)
    #expect(ReleaseVersion("v1.4.7+build.19") == ReleaseVersion("1.4.7"))
    for invalid in ["", "1.4", "1.4.x", "01.4.7", "1.4.7-", "1.4.7-alpha..1", "1.4.7-01", "1.4.7+", "1.4.7+a+b", "../1.4.7", "1.4.7/evil"] {
        #expect(ReleaseVersion(invalid) == nil)
    }
}

private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false,
                     published: String? = "2026-10-26T00:00:00Z", macPackage: Bool = true) -> GitHubRelease {
    .init(tag_name: tag, draft: draft, prerelease: prerelease, published_at: published,
          assets: macPackage ? [.init(name: "Codex-Token-Monitor-macOS-arm64.dmg")] : [])
}

@Test func updateSelectionFiltersDraftsPrereleasesAndUnusablePackages() {
    let releases = [release("v1.4.7"), release("v1.5.0-beta.1", prerelease: true),
                    release("v1.5.0-beta.2"), release("v9.0.0", draft: true),
                    release("v8.0.0", published: nil), release("v7.0.0", macPackage: false),
                    release("v6.0.0/evil"), release("v1.4.10"), release("v1.4.9")]
    #expect(GitHubRelease.newest(in: releases, includePrereleases: false)?.tag_name == "v1.4.10")
    let preview = GitHubRelease.newest(in: releases, includePrereleases: true)
    #expect(preview?.tag_name == "v1.5.0-beta.2")
    #expect(preview?.pageURL.absoluteString == "https://github.com/Naja404/codex-token-monitor/releases/tag/v1.5.0-beta.2")
}

@Test @MainActor func updateCheckerHandlesNewEqualOlderAndPreviewVersions() async {
    let identity = AppIdentity(version: "1.4.7", build: "19")
    #expect(identity.versionLabel == "v1.4.7 (19)")
    let checker = AppUpdateChecker(identity: identity) { [release("v1.4.10")] }
    await checker.check()
    #expect(checker.state == .available(tag: "v1.4.10", url: release("v1.4.10").pageURL, prerelease: false))
    for tag in ["v1.4.7", "v1.4.6"] {
        let current = AppUpdateChecker(identity: identity) { [release(tag)] }
        await current.check()
        #expect(current.state == .current)
    }
    let preview = AppUpdateChecker(identity: identity) { [release("v1.4.7"), release("v1.5.0-beta", prerelease: true)] }
    await preview.check()
    #expect(preview.state == .current)
    preview.includePrereleases = true
    #expect(preview.state == .idle)
    await preview.check()
    #expect(preview.state == .available(tag: "v1.5.0-beta", url: release("v1.5.0-beta").pageURL, prerelease: true))
}

@Test @MainActor func updateFailuresNeverClaimTheAppIsUpToDate() async {
    for error in [UpdateCheckError.rateLimited, .unavailable, .invalidResponse] {
        let checker = AppUpdateChecker(identity: .init(version: "1.4.7", build: "19")) { throw error }
        await checker.check()
        guard case .failed = checker.state else { Issue.record("Failure reported as success"); continue }
    }
    for version in [nil, "bad-version"] as [String?] {
        let checker = AppUpdateChecker(identity: .init(version: version, build: nil)) { Issue.record("Should not request GitHub with unknown local version"); return [] }
        await checker.check()
        guard case .failed = checker.state else { Issue.record("Unknown version reported as up to date"); continue }
    }
    let empty = AppUpdateChecker(identity: .init(version: "1.4.7", build: "19")) { [] }
    await empty.check()
    guard case .failed = empty.state else { Issue.record("Empty releases reported as up to date"); return }
}

@Test @MainActor func updateCheckerDoesNotStartConcurrentRequests() async {
    let counter = UpdateRequestCounter()
    let checker = AppUpdateChecker(identity: .init(version: "1.4.7", build: "19")) {
        await counter.record()
        try await Task.sleep(for: .milliseconds(30))
        return [release("v1.4.7")]
    }
    async let first: Void = checker.check()
    async let second: Void = checker.check()
    _ = await (first, second)
    #expect(await counter.count == 1)
    #expect(checker.state == .current)
}

private actor UpdateRequestCounter {
    var count = 0
    func record() { count += 1 }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["UPDATE_LIVE_CHECK"] == "1"))
func checksPublishedReleaseFeedLive() async throws {
    let releases = try await GitHubUpdateClient.releases()
    let stable = try #require(GitHubRelease.newest(in: releases, includePrereleases: false))
    #expect(!stable.prerelease)
    #expect(stable.hasMacPackage)
    #expect(stable.pageURL.host == "github.com")
    let newest = try #require(GitHubRelease.newest(in: releases, includePrereleases: true))
    #expect(try #require(newest.version) >= #require(stable.version))
}
