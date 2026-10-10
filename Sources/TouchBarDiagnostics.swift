import Foundation

/// Temporary, opt-in diagnostics. Only fixed event names and Boolean state are accepted.
@MainActor
final class TouchBarDiagnostics {
    enum Event: String {
        case launch, beforePopover, afterPopover, afterActivation, settledPopover
        case popoverClosed, appActivated, appDeactivated, windowBecameKey, windowResignedKey
        case settingsShown, settledSettings, barCreated
        case nativeText, nativeCat, nativeSample, nativeButtonPressed
        case nativeQuota
    }

    enum Field: String {
        case appActive, appFrontmost, accessoryPolicy, popoverShown, popoverWindowExists
        case popoverCanBecomeKey, popoverIsKey, settingsVisible, settingsIsKey, hasKeyWindow
        case hasFirstResponder, responderIsContentView, barCreated, barEligible, hasFourItems
        case catAnimating, presentationRequested
        case nativeProbe, nativeCatSelected, windowUsesBar, hasBundleIdentifier
        case nativeQuotaSelected
    }

    static let shared = TouchBarDiagnostics()
    static func nativeProbeRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CODEX_MONITOR_TOUCHBAR_DEBUG"] == "1" && environment["CODEX_MONITOR_TOUCHBAR_PROBE"] == "1"
    }
    let enabled: Bool
    private let sink: (String) -> Void
    private let started = ProcessInfo.processInfo.systemUptime
    private var count = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         sink: @escaping (String) -> Void = {
             FileHandle.standardError.write(Data(($0 + "\n").utf8))
         }) {
        enabled = environment["CODEX_MONITOR_TOUCHBAR_DEBUG"] == "1"
        self.sink = sink
    }

    func record(_ event: Event, state: () -> [Field: Bool] = { [:] }) {
        guard enabled, count < 400 else { return }
        count += 1
        let fields = state().sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value ? 1 : 0)" }.joined(separator: " ")
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        sink("[DEBUG-touchbar] ms=\(elapsed) event=\(event.rawValue) \(fields)")
    }
}
