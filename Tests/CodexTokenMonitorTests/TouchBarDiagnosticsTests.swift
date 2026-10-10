import AppKit
import Testing
@testable import CodexTokenMonitor

@Test @MainActor func nativeTouchBarProbeRequiresBothExplicitFlags() {
    #expect(!TouchBarDiagnostics.nativeProbeRequested(environment: [:]))
    #expect(!TouchBarDiagnostics.nativeProbeRequested(environment: ["CODEX_MONITOR_TOUCHBAR_PROBE": "1"]))
    #expect(!TouchBarDiagnostics.nativeProbeRequested(environment: ["CODEX_MONITOR_TOUCHBAR_DEBUG": "1"]))
    #expect(TouchBarDiagnostics.nativeProbeRequested(environment: [
        "CODEX_MONITOR_TOUCHBAR_DEBUG": "1", "CODEX_MONITOR_TOUCHBAR_PROBE": "1"
    ]))
}

@Test @MainActor func nativeProbeSwitchesFromStandardButtonToRealCat() throws {
    _ = NSApplication.shared
    let probe = TouchBarNativeProbe()
    defer { probe.stop() }
    probe.showText()
    let textBar = try #require(probe.window.touchBar)
    let textID = try #require(textBar.defaultItemIdentifiers.first)
    #expect(textBar.defaultItemIdentifiers.count == 1)
    #expect(textBar.item(forIdentifier: textID) is NSButtonTouchBarItem)
    probe.showCat()
    let catBar = try #require(probe.window.touchBar)
    #expect(catBar !== textBar)
    let catID = try #require(catBar.defaultItemIdentifiers.first)
    let catItem = try #require(catBar.item(forIdentifier: catID) as? NSCustomTouchBarItem)
    let cat = try #require(catItem.view as? TouchBarRainbowCatView)
    #expect(catBar.defaultItemIdentifiers.count == 1)
    #expect(cat.isAnimating == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    probe.showText()
    #expect(!cat.isAnimating)
}

@Test @MainActor func nativeProbeProvidesFullProductionBarWithOfflineValues() throws {
    _ = NSApplication.shared
    let probe = TouchBarNativeProbe()
    defer { probe.stop() }
    probe.showQuota()
    let bar = try #require(probe.window.touchBar)
    #expect(bar.templateItems.count == 4)
    let item = try #require(bar.item(forIdentifier: .init("codex.quota.fiveHour")) as? NSCustomTouchBarItem)
    let chart = try #require(item.view as? TouchBarQuotaChartView)
    #expect(chart.content?.remainingFraction == 0.7)
    let catItem = try #require(bar.item(forIdentifier: .init("codex.quota.cat")) as? NSCustomTouchBarItem)
    let cat = try #require(catItem.view as? TouchBarRainbowCatView)
    probe.showText()
    #expect(!cat.isAnimating)
}

@Test @MainActor func touchBarDiagnosticsRequireExplicitOptIn() {
    for environment in [[:], ["CODEX_MONITOR_TOUCHBAR_DEBUG": "0"], ["CODEX_MONITOR_TOUCHBAR_DEBUG": "true"]] {
        var output: [String] = []
        let logger = TouchBarDiagnostics(environment: environment, sink: { output.append($0) })
        var sampled = false
        logger.record(.launch) { sampled = true; return [.appActive: true] }
        #expect(output.isEmpty)
        #expect(!sampled)
    }
}

@Test @MainActor func touchBarDiagnosticsEmitOnlyTypedStateAndStopAtLimit() {
    var output: [String] = []
    let logger = TouchBarDiagnostics(
        environment: ["CODEX_MONITOR_TOUCHBAR_DEBUG": "1", "SECRET": "do-not-log"],
        sink: { output.append($0) }
    )
    for _ in 0..<405 {
        logger.record(.launch) { [.appActive: true, .popoverShown: false] }
    }
    #expect(output.count == 400)
    #expect(output.allSatisfy { $0.hasPrefix("[DEBUG-touchbar] ") })
    #expect(output.allSatisfy { $0.contains("event=launch appActive=1 popoverShown=0") })
    #expect(!output.joined().contains("do-not-log"))
}
