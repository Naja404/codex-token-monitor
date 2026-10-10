import Foundation
import LocalAuthentication
import Security

enum TeamoReadError: Error, Equatable, LocalizedError {
    case missingConfiguration, invalidConfiguration, importUnsupported, importUnreadable
    case keychain, unauthorized, rateLimited, invalidResponse, network, http(Int)
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "请从 .zshrc 导入或保存 TeamoRouter 配置。"
        case .invalidConfiguration: "请使用 HTTPS TeamoRouter 根地址和有效 Bearer；不支持其他代理地址。"
        case .importUnsupported: "仅支持 .zshrc 中顶层、单行的字面量赋值；动态变量或条件配置请手动填写。未执行任何 Shell 命令。"
        case .importUnreadable: "无法读取 ~/.zshrc，请手动填写配置。"
        case .keychain: "无法访问 TeamoRouter 钥匙串配置，请点击保存或验证并允许访问。"
        case .unauthorized: "TeamoRouter 密钥失效或权限不足，自动读取已暂停。"
        case .rateLimited: "TeamoRouter 请求受限，冷却期间暂停查询。"
        case .invalidResponse: "TeamoRouter 返回的数据不完整或格式不符，未将其当作零余额。"
        case .network: "无法连接 TeamoRouter，请检查网络后重试。"
        case .http(let status): "TeamoRouter 返回 HTTP \(status)，未读取成功。"
        }
    }
    var stopsAutomaticRefresh: Bool {
        [.missingConfiguration, .invalidConfiguration, .keychain, .unauthorized].contains(self)
    }
}

struct TeamoConfiguration: Codable, Sendable {
    let baseURL: String
    let token: String

    init(baseURL: String, token: String) throws {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: base), url.scheme == "https",
              ["api.teamorouter.com", "teamorouter.com"].contains(url.host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !key.isEmpty,
              key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw TeamoReadError.invalidConfiguration }
        self.baseURL = "https://" + url.host!
        self.token = key
    }

    static func environment(_ values: [String: String] = ProcessInfo.processInfo.environment) throws -> Self? {
        guard let base = values["ANTHROPIC_BASE_URL"],
              let host = URLComponents(string: base)?.host,
              ["api.teamorouter.com", "teamorouter.com"].contains(host) else { return nil }
        guard let key = values["ANTHROPIC_AUTH_TOKEN"] else { throw TeamoReadError.missingConfiguration }
        return try Self(baseURL: base, token: key)
    }

    static func importZshrc() throws -> Self {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { throw TeamoReadError.importUnreadable }
        return try parseZshrc(text)
    }

    // This is a conservative literal importer, NOT a shell evaluator. It never sources
    // files, expands variables, runs substitutions, or follows external configuration.
    static func parseZshrc(_ text: String) throws -> Self {
        let names = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"]
        var values: [String: String] = [:]
        var depth = 0
        var multilineQuote: Character?
        var heredoc: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let delimiter = heredoc {
                if line == delimiter { heredoc = nil }
                continue
            }
            if multilineQuote != nil {
                for character in line where character == multilineQuote { multilineQuote = nil; break }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let targeted = names.contains { line.contains($0) }
            if targeted {
                guard depth == 0 else { throw TeamoReadError.importUnsupported }
                let assignment = line.hasPrefix("export ") || line.hasPrefix("export\t")
                    ? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) : line
                guard let equal = assignment.firstIndex(of: "="),
                      names.contains(String(assignment[..<equal])) else { throw TeamoReadError.importUnsupported }
                let name = String(assignment[..<equal])
                let rhs = String(assignment[assignment.index(after: equal)...])
                // No substitutions, escapes, or multi-statement assignments, even inside quotes.
                guard !rhs.contains(where: { "$`\\;|&<>".contains($0) }) else { throw TeamoReadError.importUnsupported }
                let pattern = ##"^(?:'([^']*)'|"([^"]*)"|([^\s'"#]+))(?:\s+#.*)?\s*$"##
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(rhs.startIndex..., in: rhs)
                guard let match = expression.firstMatch(in: rhs, range: range) else { throw TeamoReadError.importUnsupported }
                for group in 1...3 {
                    if let valueRange = Range(match.range(at: group), in: rhs) { values[name] = String(rhs[valueRange]); break }
                }
                continue
            }
            // Track common blocks only to reject nested candidates. Unsupported quoted
            // or here-document text must never be mistaken for active assignments.
            if line.range(of: #"^(fi|done|esac|\}|\))(?:\s|;|$)"#, options: .regularExpression) != nil {
                depth = max(0, depth - 1)
            } else if line.range(of: #"^(if|for|while|until|case|function|select)(?:\s|$)|\)\s*\{$|^[{(]$"#, options: .regularExpression) != nil {
                depth += 1
            }
            if let range = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) {
                let part = String(line[range]).replacingOccurrences(of: #"[<'"\-\s]"#, with: "", options: .regularExpression)
                heredoc = part
            }
            var quote: Character?
            var escaped = false
            for character in line {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "#", quote == nil { break }
                if character == "'" || character == "\"" {
                    if quote == character { quote = nil } else if quote == nil { quote = character }
                }
            }
            multilineQuote = quote
        }
        guard let base = values[names[0]], let key = values[names[1]] else { throw TeamoReadError.missingConfiguration }
        return try Self(baseURL: base, token: key)
    }
}

enum TeamoKeychain {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CodexTokenMonitor.TeamoRouter", kSecAttrAccount as String: NSUserName()]
    }
    static func save(_ configuration: TeamoConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let result = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var entry = identity
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw TeamoReadError.keychain }
        } else if result != errSecSuccess { throw TeamoReadError.keychain }
    }
    static func read(allowInteraction: Bool) throws -> TeamoConfiguration {
        var query = identity
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            guard let config = try TeamoConfiguration.environment() else { throw TeamoReadError.missingConfiguration }
            return config
        }
        guard status == errSecSuccess, let data = result as? Data,
              let config = try? JSONDecoder().decode(TeamoConfiguration.self, from: data) else { throw TeamoReadError.keychain }
        return try TeamoConfiguration(baseURL: config.baseURL, token: config.token)
    }
}

struct TeamoUsageSnapshot: Equatable, Sendable {
    let balance: Decimal
    let cost: Decimal
    let currency: String
    let totalTokens: Int64
    let requests: Int64
    let start: Int64
    let end: Int64
    var balanceText: String { balance.formatted(.currency(code: currency)) }
    var costText: String { cost.formatted(.currency(code: currency).precision(.fractionLength(2...4))) }

    static func parse(balance: Data, costs: Data, usage: Data, start: Int64, end: Int64) throws -> Self {
        struct Money: Decodable { let value: String; let currency: String }
        struct Balance: Decodable { let balance: Money }
        struct Costs: Decodable { let start_time: Int64; let end_time: Int64; let total_amount: Money; let requests: Int64 }
        struct Tokens: Decodable { let total_tokens: Int64 }
        struct Usage: Decodable { let start_time: Int64; let end_time: Int64; let usage: Tokens; let requests: Int64 }
        let decoder = JSONDecoder()
        guard let b = try? decoder.decode(Balance.self, from: balance),
              let c = try? decoder.decode(Costs.self, from: costs),
              let u = try? decoder.decode(Usage.self, from: usage),
              b.balance.currency == "USD", c.total_amount.currency == b.balance.currency,
              b.balance.value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              c.total_amount.value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: b.balance.value, locale: Locale(identifier: "en_US_POSIX")),
              let cost = Decimal(string: c.total_amount.value, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, !cost.isNaN, cost >= 0,
              start < end, c.start_time == start, u.start_time == start, c.end_time == end, u.end_time == end,
              u.usage.total_tokens >= 0, u.requests >= 0, c.requests >= 0 else { throw TeamoReadError.invalidResponse }
        return .init(balance: amount, cost: cost, currency: b.balance.currency,
                     totalTokens: u.usage.total_tokens, requests: u.requests, start: start, end: end)
    }
}

struct TeamoUsageFailure: Error { let reason: TeamoReadError; let retryAt: Date? }

private final class TeamoNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct TeamoUsageReader: Sendable {
    static func request(_ config: TeamoConfiguration, path: String, start: Int64? = nil, end: Int64? = nil) throws -> URLRequest {
        let config = try TeamoConfiguration(baseURL: config.baseURL, token: config.token)
        guard ["/v1/billing/balance", "/v1/billing/costs", "/v1/usage"].contains(path),
              var url = URLComponents(string: config.baseURL + path) else { throw TeamoReadError.invalidConfiguration }
        if path != "/v1/billing/balance" {
            guard let start, let end, start < end else { throw TeamoReadError.invalidConfiguration }
            url.queryItems = [.init(name: "start_time", value: String(start)), .init(name: "end_time", value: String(end))]
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func read(allowInteraction: Bool = false) async throws -> TeamoUsageSnapshot {
        let config = try await Task.detached { try TeamoKeychain.read(allowInteraction: allowInteraction) }.value
        return try await read(configuration: config)
    }

    func read(configuration: TeamoConfiguration, now: Date = .now) async throws -> TeamoUsageSnapshot {
        let start = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let end = max(start + 1, Int64(now.timeIntervalSince1970))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: TeamoNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            // Sequential read-only calls stop immediately on auth errors or rate limits.
            let balance = try await fetch(session, request: Self.request(configuration, path: "/v1/billing/balance"))
            let costs = try await fetch(session, request: Self.request(configuration, path: "/v1/billing/costs", start: start, end: end))
            let usage = try await fetch(session, request: Self.request(configuration, path: "/v1/usage", start: start, end: end))
            return try TeamoUsageSnapshot.parse(balance: balance, costs: costs, usage: usage, start: start, end: end)
        } catch let error as TeamoReadError { throw error }
        catch let error as TeamoUsageFailure { throw error }
        catch { try Task.checkCancellation(); throw TeamoReadError.network }
    }

    private func fetch(_ session: URLSession, request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TeamoReadError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw TeamoReadError.unauthorized
        case 429: throw TeamoUsageFailure(reason: .rateLimited,
            retryAt: DirectClaudeUsageReader.retryDate(response.value(forHTTPHeaderField: "Retry-After")))
        default: throw TeamoReadError.http(response.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw TeamoReadError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
