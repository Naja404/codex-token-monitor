import AppKit
import Combine
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Test @MainActor func appearanceDefaultsPersistAndRejectUnknownValues() throws {
    let name = "appearance-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let appearance = MonitorAppearance(defaults: defaults)
    #expect(appearance.theme == .native)
    #expect(appearance.mode == .system)
    #expect(appearance.motion == .gentle)
    appearance.theme = .aurora
    appearance.mode = .dark
    appearance.motion = .off
    let restored = MonitorAppearance(defaults: defaults)
    #expect(restored.theme == .aurora)
    #expect(restored.mode == .dark)
    #expect(restored.motion == .off)
    defaults.set("unknown-future-theme", forKey: "monitorTheme")
    #expect(MonitorAppearance(defaults: defaults).theme == .native)
}

@MainActor private final class PulsePreviewState: ObservableObject {
    @Published var successAt: Date?
}

private struct PulsePreview: View {
    @ObservedObject var state: PulsePreviewState
    var motion: Bool
    var body: some View {
        Text("Quota 72%").frame(width: 180, height: 50).monitorSurface(successAt: state.successAt)
            .padding(8).environment(\.monitorStyle, MonitorStyle(theme: .aurora, dark: true, motionEnabled: motion))
            .environment(\.colorScheme, .dark)
    }
}

@Test @MainActor func disabledRefreshPulseLeavesPixelsUnchanged() async throws {
    _ = NSApplication.shared
    let state = PulsePreviewState()
    let host = NSHostingView(rootView: PulsePreview(state: state, motion: false))
    host.frame = NSRect(x: 0, y: 0, width: 196, height: 66)
    func snapshot() throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
    let before = try snapshot()
    state.successAt = .now
    try await Task.sleep(for: .milliseconds(100))
    #expect(try snapshot() == before)
}

@Test func appearanceResolvesSystemAndHonorsMotionRestrictions() {
    #expect(MonitorColorMode.system.resolve(.dark) == .dark)
    #expect(MonitorColorMode.light.resolve(.dark) == .light)
    #expect(MonitorColorMode.dark.resolve(.light) == .dark)
    #expect(MonitorMotion.gentle.allowsAnimation(reduceMotion: false, visible: true, active: true))
    #expect(!MonitorMotion.off.allowsAnimation(reduceMotion: false, visible: true, active: true))
    #expect(!MonitorMotion.gentle.allowsAnimation(reduceMotion: true, visible: true, active: true))
    #expect(!MonitorMotion.gentle.allowsAnimation(reduceMotion: false, visible: false, active: true))
    #expect(!MonitorMotion.gentle.allowsAnimation(reduceMotion: false, visible: true, active: false))
}

@Test @MainActor func appearanceDoesNotMutateProviderSelectionOrQuota() {
    let name = "theme-provider-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    defer { store.stop() }
    let lines = store.menuLines
    for theme in MonitorTheme.allCases { store.appearance.theme = theme }
    #expect(store.menuSource == .codex)
    #expect(store.menuLines.first == lines.first)
    #expect(!store.isRefreshingWarp && !store.isRefreshingClaude)
    store.beginPopover()
    #expect(store.popoverVisible)
    store.endPopover()
    #expect(!store.popoverVisible)
}

@Test @MainActor func themeTextContrastOnOpaqueSurfaces() throws {
    func luminance(_ color: NSColor) throws -> Double {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152 + linear(rgb.blueComponent) * 0.0722
    }
    for theme in MonitorTheme.allCases {
        for dark in [false, true] {
            let palette = ThemePalette(theme: theme, dark: dark)
            for surface in [palette.background, palette.card] {
                for text in [palette.primary, palette.secondary] {
                    let a = try luminance(surface), b = try luminance(text)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }
}
