import Foundation
import SwiftUI

struct AppIdentity: Sendable {
    static let repositoryURL = URL(string: "https://github.com/Naja404/codex-token-monitor")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static var current: AppIdentity {
        .init(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
    let version: String?
    let build: String?
    var versionLabel: String {
        guard let version else { return L10n.text("开发版本") }
        return "v\(version)" + (build.map { " (\($0))" } ?? "")
    }
}

struct ReleaseVersion: Comparable, Sendable {
    let core: [Int]
    let prerelease: [String]

    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let buildParts = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        func validIdentifier(_ value: Substring) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        if buildParts.count == 2 {
            guard buildParts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy(validIdentifier) else { return nil }
        }
        let parts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0 == "0" || !$0.hasPrefix("0")) }),
              numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        core = numbers.compactMap { Int($0) }
        let identifiers = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false) : []
        guard identifiers.allSatisfy({ validIdentifier($0) && (!$0.utf8.allSatisfy { (48...57).contains($0) } || $0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
        prerelease = identifiers.map(String.init)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = left.utf8.allSatisfy { (48...57).contains($0) }
            let rn = right.utf8.allSatisfy { (48...57).contains($0) }
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable { let name: String }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]

    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    var pageURL: URL { AppIdentity.repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }
    var hasMacPackage: Bool {
        assets.contains { ["Codex-Token-Monitor-macOS-arm64.dmg", "Codex-Token-Monitor-macOS-arm64.zip"].contains($0.name) }
    }
    static func newest(in releases: [Self], includePrereleases: Bool) -> Self? {
        releases.filter {
            !$0.draft && $0.published_at != nil && $0.hasMacPackage && $0.version != nil &&
            (includePrereleases || (!$0.prerelease && $0.version!.prerelease.isEmpty))
        }.max { $0.version! < $1.version! }
    }
}

enum UpdateCheckError: Error, Equatable { case rateLimited, unavailable, invalidResponse }

enum GitHubUpdateClient {
    static let endpoint = URL(string: "https://api.github.com/repos/Naja404/codex-token-monitor/releases?per_page=100")!

    static func releases() async throws -> [GitHubRelease] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenMonitor/\(AppIdentity.current.version ?? "development")", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        if http.statusCode == 403 || http.statusCode == 429 { throw UpdateCheckError.rateLimited }
        guard http.statusCode == 200 else { throw UpdateCheckError.unavailable }
        guard data.count <= 2_000_000 else { throw UpdateCheckError.invalidResponse }
        do { return try JSONDecoder().decode([GitHubRelease].self, from: data) }
        catch { throw UpdateCheckError.invalidResponse }
    }
}

@MainActor final class AppUpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, available(tag: String, url: URL, prerelease: Bool), failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published var includePrereleases = false { didSet { if state != .checking { state = .idle } } }
    let identity: AppIdentity
    private let load: @Sendable () async throws -> [GitHubRelease]

    init(identity: AppIdentity = .current, load: @escaping @Sendable () async throws -> [GitHubRelease] = { try await GitHubUpdateClient.releases() }) {
        self.identity = identity
        self.load = load
    }

    func check() async {
        guard state != .checking else { return }
        guard let rawVersion = identity.version, let current = ReleaseVersion(rawVersion) else {
            state = .failed("无法读取当前版本，请打开 GitHub 发布页查看。")
            return
        }
        let includePrereleases = includePrereleases
        state = .checking
        do {
            let releases = try await load()
            guard let latest = GitHubRelease.newest(in: releases, includePrereleases: includePrereleases), let version = latest.version else {
                state = .failed("没有找到可用的 macOS 发布版本。")
                return
            }
            state = version > current ? .available(tag: latest.tag_name, url: latest.pageURL,
                                                    prerelease: latest.prerelease || !version.prerelease.isEmpty) : .current
        } catch {
            state = .failed(error as? UpdateCheckError == .rateLimited
                ? "GitHub 请求已限流，请稍后重试。" : "检查更新失败，请检查网络后重试。")
        }
    }
}

struct AppAboutView: View {
    @StateObject private var checker = AppUpdateChecker()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Codex Token Monitor").font(.headline)
            LabeledContent(L10n.text("当前版本"), value: checker.identity.versionLabel)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("项目地址")).font(.subheadline.weight(.semibold))
                Link(AppIdentity.repositoryURL.absoluteString, destination: AppIdentity.repositoryURL)
                    .textSelection(.enabled)
            }
            Divider()
            Toggle(L10n.text("包含预发布版本"), isOn: $checker.includePrereleases)
                .disabled(checker.state == .checking)
            Text(L10n.text("默认仅检查正式版。预发布版可能尚未完成 Apple 公证，请阅读发布说明。"))
                .font(.caption).monitorSecondary()
            HStack(spacing: 12) {
                Button(L10n.text("检查更新")) { Task { await checker.check() } }
                    .buttonStyle(.borderedProminent).disabled(checker.state == .checking)
                if checker.state == .checking { ProgressView().controlSize(.small); Text(L10n.text("正在检查更新…")) }
            }
            switch checker.state {
            case .idle, .checking: EmptyView()
            case .current: Label(L10n.text("当前已是最新版本。"), systemImage: "checkmark.circle")
            case let .available(tag, url, prerelease):
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.format("发现新版本 %@", tag)).font(.headline)
                    if prerelease { Text(L10n.text("预发布版本")).font(.caption).monitorSecondary() }
                    Link(L10n.text("查看更新并下载"), destination: url)
                }
            case let .failed(message):
                Label(L10n.text(message), systemImage: "exclamationmark.triangle")
            }
            Text(L10n.text("仅在点击时连接 GitHub 检查版本；下载与安装由你确认。"))
                .font(.caption).monitorSecondary()
            Link(L10n.text("打开所有发布版本"), destination: AppIdentity.releasesURL)
        }.padding(16).monitorSurface()
    }
}
