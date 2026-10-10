import Darwin
import Foundation

struct QuotaMetric: Identifiable, Equatable, Sendable {
    let id: String
    let window: String
    let remainingPercent: Double
    let resetsAt: Date?

    var title: String {
        switch window {
        case "5h": "5 小时"
        case "weekly": "每周"
        default: window
        }
    }
}

struct QuotaGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let metrics: [QuotaMetric]
}

enum ProviderReadError: Error, Equatable, LocalizedError {
    case notInstalled, invalidPath, unsupportedCLI, launchFailed, timeout, outputLimit
    case missingCredentials, permissionDenied, rateLimited, network, invalidResponse, unsafeCommand
    case credentialsExpired, credentialAccessDenied
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 agy。请安装官方 Antigravity CLI，或选择已安装的可执行文件。"
        case .invalidPath: "CLI 路径不可执行。请选择 agy 文件的绝对路径。"
        case .unsupportedCLI: "需要 agy 1.1.11 或更新的正式版本。请更新 CLI 后重新验证。"
        case .launchFailed: "CLI 无法启动。请检查文件权限或重新安装。"
        case .timeout: "查询超时，已停止本次进程。请检查网络后重试。"
        case .outputLimit: "CLI 输出超过安全上限，已停止查询。请检查版本。"
        case .missingCredentials: "未找到有效登录。请先在对应官方客户端或 CLI 中登录，再验证。"
        case .credentialsExpired: "Claude Code 登录已过期。请在 Claude Code 中重新登录，再点击验证连接。"
        case .credentialAccessDenied: "无法读取 Claude Code 钥匙串。请解锁登录钥匙串，点击验证连接并允许访问。"
        case .permissionDenied: "账号没有查询权限或订阅资格。请检查当前登录账号。"
        case .rateLimited: "服务暂时限流，自动刷新已放缓。请稍后重试。"
        case .network: "请求失败。请检查网络、代理和官方服务状态后重试。"
        case .invalidResponse: "没有读到有效额度，可能是接口格式变化。请更新客户端后重试。"
        case .unsafeCommand: "CLI 将额度查询识别为对话，已暂停自动查询。请更新 agy 后重新验证。"
        case .http(let code): "服务返回 HTTP \(code)。请稍后重试。"
        }
    }

    var stopsAutomaticRefresh: Bool {
        switch self {
        case .notInstalled, .invalidPath, .unsupportedCLI, .missingCredentials, .permissionDenied, .unsafeCommand,
             .credentialsExpired, .credentialAccessDenied: true
        default: false
        }
    }
}

enum AntigravityReport {
    static func parse(_ text: String) throws -> [QuotaGroup] {
        var reports: [[String: Any]] = []
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            reports = [object]
        } else {
            reports = text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        // Do not accept a quota-looking payload if any report indicates a model turn.
        for report in reports {
            if (report["num_turns"] as? Int ?? 0) > 0 || !(report["conversation_id"] as? String ?? "").isEmpty {
                throw ProviderReadError.unsafeCommand
            }
        }
        for report in reports {
            guard report["status"] as? String == "SUCCESS",
                  let command = report["command"] as? [String: Any], command["name"] as? String == "usage",
                  let data = command["data"] as? [String: Any], let groups = data["groups"] as? [[String: Any]] else { continue }
            let formatter = ISO8601DateFormatter()
            var result: [QuotaGroup] = []
            for (index, group) in groups.enumerated() {
                guard let name = group["name"] as? String, !name.isEmpty,
                      let buckets = group["buckets"] as? [[String: Any]] else { continue }
                var seen = Set<String>()
                let metrics = buckets.compactMap { bucket -> QuotaMetric? in
                    guard bucket["disabled"] as? Bool != true,
                          let id = bucket["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                          let fraction = bucket["remaining_fraction"] as? NSNumber,
                          CFGetTypeID(fraction) != CFBooleanGetTypeID(),
                          fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue),
                          let window = bucket["window"] as? String, !window.isEmpty else { return nil }
                    var reset: Date?
                    if let text = bucket["reset_time"] as? String {
                        formatter.formatOptions = [.withInternetDateTime]
                        reset = formatter.date(from: text)
                        if reset == nil {
                            formatter.formatOptions.insert(.withFractionalSeconds)
                            reset = formatter.date(from: text)
                        }
                    }
                    return QuotaMetric(id: id, window: window, remainingPercent: fraction.doubleValue * 100, resetsAt: reset)
                }
                if !metrics.isEmpty {
                    let id = metrics.contains(where: { $0.id.hasPrefix("gemini-") }) ? "gemini" :
                        metrics.contains(where: { $0.id.hasPrefix("3p-") }) ? "3p" : "group-\(index)"
                    result.append(QuotaGroup(id: id, name: name, metrics: metrics))
                }
            }
            if !result.isEmpty { return result }
        }
        throw ProviderReadError.invalidResponse
    }
}

struct CLIInstallation: Equatable, Sendable {
    let path: String
    let version: String
}

struct AntigravitySnapshot: Sendable {
    let installation: CLIInstallation
    let groups: [QuotaGroup]
}

struct AntigravityReader: Sendable {
    static func supports(version: String) -> Bool {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return false }
        return major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)))
    }

    static func resolvePath(override: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = FileManager.default
        if !custom.isEmpty {
            let values = try? URL(fileURLWithPath: custom).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
            guard custom.hasPrefix("/"), manager.isExecutableFile(atPath: custom),
                  values?.isRegularFile == true else {
                throw ProviderReadError.invalidPath
            }
            return custom
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.antigravity/antigravity/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("agy").path
            if manager.isExecutableFile(atPath: path),
               (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return path }
        }
        throw ProviderReadError.notInstalled
    }

    func detect(pathOverride: String) async throws -> CLIInstallation {
        let path = try Self.resolvePath(override: pathOverride)
        let result = try await QuotaCommand.run(executable: path, arguments: ["--version"], timeout: 5)
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, Self.supports(version: version) else { throw ProviderReadError.unsupportedCLI }
        return CLIInstallation(path: path, version: version)
    }

    func read(pathOverride: String) async throws -> AntigravitySnapshot {
        let installation = try await detect(pathOverride: pathOverride)
        try Task.checkCancellation()
        let result = try await QuotaCommand.run(executable: installation.path,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"], timeout: 30)
        // Classify diagnostics locally; never surface raw CLI output or credentials.
        let diagnostic = (result.stderr + "\n" + result.stdout).lowercased()
        if diagnostic.contains("unauthenticated") || diagnostic.contains("not logged in") || diagnostic.contains("not signed in") {
            throw ProviderReadError.missingCredentials
        }
        if diagnostic.contains("permission_denied") { throw ProviderReadError.permissionDenied }
        if diagnostic.contains("resource_exhausted") { throw ProviderReadError.rateLimited }
        let groups: [QuotaGroup]
        do { groups = try AntigravityReport.parse(result.stdout) }
        catch ProviderReadError.unsafeCommand { throw ProviderReadError.unsafeCommand }
        catch { throw result.exitCode == 0 ? ProviderReadError.invalidResponse : ProviderReadError.network }
        guard result.exitCode == 0 else { throw ProviderReadError.network }
        return AntigravitySnapshot(installation: installation, groups: groups)
    }
}

struct QuotaCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum QuotaCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    outputLimit: Int = 512 * 1024) async throws -> QuotaCommandResult {
        let task = Task.detached(priority: .utility) {
            try execute(executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func execute(executable: String, arguments: [String], timeout: TimeInterval,
                                outputLimit: Int) throws -> QuotaCommandResult {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("quota-probe-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw ProviderReadError.launchFailed }
        defer { close(out[0]); close(out[1]) }
        guard pipe(&err) == 0 else { throw ProviderReadError.launchFailed }
        defer { close(err[0]); close(err[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, out[0])
        posix_spawn_file_actions_addclose(&actions, err[0])
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        // A separate process group lets cancellation clean up ONLY this probe's descendants.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        guard code == 0 else { throw ProviderReadError.launchFailed }
        // Keep the group leader unreaped until cleanup, preventing PID reuse while signaling.
        defer {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        _ = fcntl(out[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(err[0], F_SETFL, O_NONBLOCK)
        var stdout = Data(), stderr = Data()
        let start = ProcessInfo.processInfo.systemUptime
        func drain(_ fd: Int32, into data: inout Data) throws {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                guard data.count + count <= outputLimit else { throw ProviderReadError.outputLimit }
                data.append(contentsOf: buffer.prefix(count))
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime - start >= timeout { throw ProviderReadError.timeout }
            }
        }
        while true {
            try Task.checkCancellation()
            try drain(out[0], into: &stdout)
            try drain(err[0], into: &stderr)
            guard stdout.count + stderr.count <= outputLimit else { throw ProviderReadError.outputLimit }
            var info = siginfo_t()
            guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
                throw ProviderReadError.launchFailed
            }
            if info.si_pid == pid {
                try drain(out[0], into: &stdout)
                try drain(err[0], into: &stderr)
                guard stdout.count + stderr.count <= outputLimit else { throw ProviderReadError.outputLimit }
                return QuotaCommandResult(stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitCode: info.si_code == CLD_EXITED ? info.si_status : -1)
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { throw ProviderReadError.timeout }
            usleep(10_000)
        }
    }
}
