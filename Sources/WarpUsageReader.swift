import Foundation
import LocalAuthentication
import Security

enum WarpReadError: Error, Equatable, LocalizedError {
    case missingKey, keychain, unauthorized, rateLimited, invalidResponse, network, http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请保存 Warp 个人 API Key 后验证。"
        case .keychain: "无法访问钥匙串，请点击保存或验证并允许访问。"
        case .unauthorized: "Warp 密钥失效或权限不足；请更换个人 API Key。自动读取已暂停。"
        case .rateLimited: "Warp 请求受限，冷却期间暂停查询。"
        case .invalidResponse: "Warp 未返回可识别的额度，内部接口可能已变化。"
        case .network: "无法连接 Warp，请检查网络后重试。"
        case .http(let code): "Warp 返回 HTTP \(code)，稍后重试。"
        }
    }
    var stopsAutomaticRefresh: Bool {
        self == .missingKey || self == .keychain || self == .unauthorized
    }
}

struct WarpUsageSnapshot: Equatable, Sendable {
    let limit: Double
    let used: Double
    let unlimited: Bool
    let resetsAt: Date?
    let bonusRemaining: Double?
    var remaining: Double { max(0, limit - used) }
    var balanceText: String { unlimited ? "无上限" : remaining.formatted(.number.precision(.fractionLength(0...1))) + " Credits" }
    var metric: QuotaMetric? {
        guard !unlimited, limit > 0 else { return nil }
        return .init(id: "warp-cycle", window: "cycle", remainingPercent: remaining / limit * 100, resetsAt: resetsAt)
    }

    static func parse(_ data: Data, now: Date = .now) throws -> Self {
        struct Envelope: Decodable { let data: Payload?; let errors: [GraphError]? }
        struct GraphError: Decodable { let message: String? }
        struct Payload: Decodable { let user: Output }
        struct Output: Decodable { let user: Account? }
        struct Account: Decodable { let requestLimitInfo: Limit; let bonusGrants: [Grant]? }
        struct Limit: Decodable {
            let isUnlimited: Bool
            let requestLimit: Double
            let requestsUsedSinceLastRefresh: Double
            let nextRefreshTime: String?
        }
        struct Grant: Decodable { let requestCreditsRemaining: Double; let expiration: String? }
        guard let response = try? JSONDecoder().decode(Envelope.self, from: data),
              response.errors?.isEmpty != false, let account = response.data?.user.user else {
            throw WarpReadError.invalidResponse
        }
        let limit = account.requestLimitInfo
        guard limit.requestLimit.isFinite, limit.requestLimit >= 0,
              limit.requestsUsedSinceLastRefresh.isFinite, limit.requestsUsedSinceLastRefresh >= 0 else {
            throw WarpReadError.invalidResponse
        }
        var bonus: Double?
        if let grants = account.bonusGrants {
            var total = 0.0
            for grant in grants {
                guard grant.requestCreditsRemaining.isFinite, grant.requestCreditsRemaining >= 0 else {
                    throw WarpReadError.invalidResponse
                }
                // Unknown expiration cannot be counted as confirmed available credits.
                if let expiration = grant.expiration {
                    guard let date = date(expiration) else { throw WarpReadError.invalidResponse }
                    if date <= now { continue }
                }
                total += grant.requestCreditsRemaining
            }
            guard total.isFinite else { throw WarpReadError.invalidResponse }
            bonus = total
        }
        return .init(limit: limit.requestLimit, used: limit.requestsUsedSinceLastRefresh,
                     unlimited: limit.isUnlimited, resetsAt: date(limit.nextRefreshTime), bonusRemaining: bonus)
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum WarpKeychain {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CodexTokenMonitor.WarpAPIKey", kSecAttrAccount as String: NSUserName()]
    }
    static func validate(_ key: String) throws -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("wk-"), key.count > 3,
              !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw WarpReadError.missingKey }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(try validate(key).utf8)
        let values = [kSecValueData as String: data]
        let result = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            var entry = identity
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw WarpReadError.keychain }
        } else if result != errSecSuccess { throw WarpReadError.keychain }
    }
    static func read(allowInteraction: Bool) throws -> String {
        var query = identity
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw WarpReadError.missingKey }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw WarpReadError.keychain
        }
        return try validate(key)
    }
}

struct WarpUsageFailure: Error { let reason: WarpReadError; let retryAt: Date? }

private final class WarpNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct WarpUsageReader: Sendable {
    static func request(key: String) throws -> URLRequest {
        let key = try WarpKeychain.validate(key)
        var request = URLRequest(url: URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("Warp/1.0", forHTTPHeaderField: "User-Agent")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        for (key, value) in ["x-warp-os-category": "macOS", "x-warp-os-name": "macOS", "x-warp-os-version": osVersion] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Only personal credits. Workspace grants are deliberately not requested or combined.
        let query = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            ... on UserOutput {
              user {
                requestLimitInfo { isUnlimited requestLimit requestsUsedSinceLastRefresh nextRefreshTime }
                bonusGrants { requestCreditsRemaining expiration }
              }
            }
          }
        }
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": "GetRequestLimitInfo", "query": query,
            "variables": ["requestContext": ["clientContext": [:],
                                             "osContext": ["category": "macOS", "name": "macOS", "version": osVersion]]]
        ])
        return request
    }

    func read(allowInteraction: Bool = false) async throws -> WarpUsageSnapshot {
        let key = try await Task.detached { try WarpKeychain.read(allowInteraction: allowInteraction) }.value
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: WarpNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(key: key))
            guard let response = response as? HTTPURLResponse else { throw WarpReadError.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw WarpReadError.unauthorized
            case 429: throw WarpUsageFailure(reason: .rateLimited,
                retryAt: DirectClaudeUsageReader.retryDate(response.value(forHTTPHeaderField: "Retry-After")))
            default: throw WarpReadError.http(response.statusCode)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 512 * 1024 else { throw WarpReadError.invalidResponse }
                data.append(byte)
            }
            return try WarpUsageSnapshot.parse(data)
        } catch let error as WarpReadError { throw error }
        catch let error as WarpUsageFailure { throw error }
        catch { try Task.checkCancellation(); throw WarpReadError.network }
    }
}
