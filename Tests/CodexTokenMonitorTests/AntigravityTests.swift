import Foundation
import Darwin
import Testing
@testable import CodexTokenMonitor

let antigravityFixture = """
{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
{"name":"Gemini Models","buckets":[
{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9818,"reset_time":"2026-10-13T10:22:14Z"},
{"id":"gemini-5h","window":"5h","remaining_fraction":0.9992,"reset_time":"2026-10-10T15:11:15Z"}]},
{"name":"Claude and GPT models","buckets":[
{"id":"3p-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-17T13:13:58Z"},
{"id":"3p-5h","window":"5h","remaining_fraction":0,"reset_time":"2026-10-10T18:13:58Z"}]}]}}}
"""

@Test func parsesAntigravityGroupsWithoutMergingPools() throws {
    let groups = try AntigravityReport.parse(antigravityFixture)
    #expect(groups.count == 2)
    #expect(groups[0].metrics.count == 2)
    #expect(groups[0].metrics.first(where: { $0.window == "weekly" })?.remainingPercent == 98.18)
    #expect(groups[1].metrics.first(where: { $0.window == "5h" })?.remainingPercent == 0)
    #expect(groups[0].metrics[0].resetsAt != nil)
}

@Test func keepsPartialQuotaAndMissingResetWithoutInventingData() throws {
    let report = """
    {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[
    {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.3},
    {"id":"gemini-5h","window":"5h","disabled":true,"remaining_fraction":0.9},
    {"id":"bad","window":"5h","remaining_fraction":2},
    {"id":"missing","window":"5h"}]}]}}}
    """
    let groups = try AntigravityReport.parse(report)
    #expect(groups[0].metrics.count == 1)
    #expect(groups[0].metrics[0].remainingPercent == 30)
    #expect(groups[0].metrics[0].resetsAt == nil)
}

@Test(arguments: ["{}", "{\"status\":\"SUCCESS\",\"response\":\"100%\"}",
                  "{\"status\":\"SUCCESS\",\"command\":{\"name\":\"usage\",\"data\":{\"groups\":[]}}}"])
func rejectsNonQuotaReports(report: String) {
    #expect(throws: ProviderReadError.self) { try AntigravityReport.parse(report) }
}

@Test func rejectsModelConversationEvenWithQuotaPayload() {
    let report = antigravityFixture.replacingOccurrences(of: "\"num_turns\":0", with: "\"num_turns\":1")
    #expect(throws: ProviderReadError.unsafeCommand) { try AntigravityReport.parse(report) }
}

@Test func acceptsJSONLineReportAfterStartupNotice() throws {
    #expect(try AntigravityReport.parse("Starting CLI\n" + antigravityFixture.replacingOccurrences(of: "\n", with: "") + "\n").count == 2)
}

@Test(arguments: [("1.1.10", false), ("1.1.11", true), ("1.3.2", true), ("2.0.0", true), ("unknown", false)])
func checksCLIVersion(version: String, supported: Bool) {
    #expect(AntigravityReader.supports(version: version) == supported)
}

@Test func commandRunnerCapturesOutputAndExit() async throws {
    let result = try await QuotaCommand.run(executable: "/bin/sh", arguments: ["-c", "printf hello; printf warning >&2; exit 7"], timeout: 2)
    #expect(result.stdout == "hello")
    #expect(result.stderr == "warning")
    #expect(result.exitCode == 7)
}

@Test func commandRunnerTimesOutAndDoesNotBlockMainActor() async {
    await #expect(throws: ProviderReadError.timeout) {
        try await QuotaCommand.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)
    }
}

@Test func commandRunnerCapsOutput() async {
    await #expect(throws: ProviderReadError.outputLimit) {
        try await QuotaCommand.run(executable: "/usr/bin/yes", arguments: [], timeout: 2, outputLimit: 1024)
    }
}

@Test func commandRunnerCancels() async {
    let task = Task { try await QuotaCommand.run(executable: "/bin/sleep", arguments: ["5"], timeout: 5) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func acceptsSymlinkCLIPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("agy")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
    #expect(try AntigravityReader.resolvePath(override: link.path) == link.path)
}

@Test func commandRunnerCancelsAfterStarting() async throws {
    let start = ContinuousClock.now
    let task = Task { try await QuotaCommand.run(executable: "/bin/sleep", arguments: ["5"], timeout: 5) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func commandRunnerCleansUpOwnProcessGroup() async throws {
    let result = try await QuotaCommand.run(executable: "/bin/sh",
        arguments: ["-c", "sleep 10 & printf '%s' $!"], timeout: 2)
    let child = try #require(Int32(result.stdout))
    for _ in 0..<100 {
        if kill(child, 0) == -1 && errno == ESRCH { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Probe child process survived group cleanup")
}

@Test func invalidResetDoesNotDiscardValidPercentage() throws {
    let report = antigravityFixture.replacingOccurrences(of: "2026-10-13T10:22:14Z", with: "not-a-date")
    let metric = try #require(AntigravityReport.parse(report).first?.metrics.first)
    #expect(metric.remainingPercent == 98.18)
    #expect(metric.resetsAt == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ANTIGRAVITY_LIVE_CLI"] != nil))
func readsInstalledAntigravityCLI() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ANTIGRAVITY_LIVE_CLI"])
    let snapshot = try await AntigravityReader().read(pathOverride: path)
    #expect(!snapshot.groups.isEmpty)
    #expect(snapshot.groups.flatMap(\.metrics).allSatisfy { (0...100).contains($0.remainingPercent) })
    print("Live Antigravity CLI verified: \(snapshot.groups.count) quota groups, \(snapshot.groups.flatMap(\.metrics).count) windows")
}
