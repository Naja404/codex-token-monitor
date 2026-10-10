import Foundation
import LocalAuthentication
import Security

struct ClaudeUsageSnapshot: Sendable {
    let metrics: [QuotaMetric]
    let planName: String
}

enum ClaudeUsageReport {
    static func parse(_ data: Data) throws -> [QuotaMetric] {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderReadError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        let metrics = [("five_hour", "5h"), ("seven_day", "weekly")].compactMap { key, window -> QuotaMetric? in
            guard let value = report[key] as? [String: Any], let used = value["utilization"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite,
                  (0...100).contains(used.doubleValue) else { return nil }
            var reset: Date?
            if let text = value["resets_at"] as? String {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
                if reset == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    reset = formatter.date(from: text)
                }
            }
            return QuotaMetric(id: key, window: window, remainingPercent: 100 - used.doubleValue, resetsAt: reset)
        }
        guard !metrics.isEmpty else { throw ProviderReadError.invalidResponse }
        return metrics
    }
}

struct ClaudeCredential: Sendable {
    let accessToken: String
    let planName: String

    static func parse(_ data: Data, now: Date = .now) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\n"), !token.contains("\r") else { throw ProviderReadError.missingCredentials }
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= now.timeIntervalSince1970 {
            throw ProviderReadError.credentialsExpired
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") {
            throw ProviderReadError.permissionDenied
        }
        let plan: String
        switch (oauth["subscriptionType"] as? String)?.lowercased() {
        case "pro": plan = "Pro"
        case "max": plan = "Max"
        case "team": plan = "Team"
        case "enterprise": plan = "Enterprise"
        default: plan = "订阅套餐未识别"
        }
        return .init(accessToken: token, planName: plan)
    }

    // Read only the default Claude Code login, never scan other Keychain entries.
    // Automatic polling cannot prompt; the user can explicitly grant access via Verify.
    static func read(allowInteraction: Bool) throws -> Self {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try parse(data) }
        guard status == errSecItemNotFound else { throw ProviderReadError.credentialAccessDenied }
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024 else {
            throw ProviderReadError.missingCredentials
        }
        return try parse(data)
    }
}

struct ClaudeUsageFailure: Error {
    let reason: ProviderReadError
    let retryAt: Date?
}

private final class ClaudeNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DirectClaudeUsageReader: Sendable {
    static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func validate(statusCode: Int) throws {
        switch statusCode {
        case 200: return
        case 401: throw ProviderReadError.credentialsExpired
        case 403: throw ProviderReadError.permissionDenied
        case 429: throw ProviderReadError.rateLimited
        default: throw ProviderReadError.http(statusCode)
        }
    }

    static func retryDate(_ value: String?, now: Date = .now) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).flatMap { $0 > now ? $0 : nil }
    }

    func read(allowInteraction: Bool = false) async throws -> ClaudeUsageSnapshot {
        let credential = try await Task.detached {
            try ClaudeCredential.read(allowInteraction: allowInteraction)
        }.value
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: ClaudeNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(accessToken: credential.accessToken))
            guard let response = response as? HTTPURLResponse else { throw ProviderReadError.invalidResponse }
            do { try Self.validate(statusCode: response.statusCode) }
            catch let error as ProviderReadError {
                throw ClaudeUsageFailure(reason: error, retryAt: Self.retryDate(response.value(forHTTPHeaderField: "Retry-After")))
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 512 * 1024 else { throw ProviderReadError.invalidResponse }
                data.append(byte)
            }
            return .init(metrics: try ClaudeUsageReport.parse(data), planName: credential.planName)
        } catch let error as ProviderReadError {
            throw error
        } catch let error as ClaudeUsageFailure {
            throw error
        } catch {
            try Task.checkCancellation()
            throw ProviderReadError.network
        }
    }
}
