import AppKit
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Suite(.serialized) @MainActor
struct SettingsNavigationTests {
    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func rightHandBlankSpaceHitsEveryNavigationRow(language: AppLanguage) async throws {
        _ = NSApplication.shared
        let name = "sidebar-hit-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "codexEnabled")
        let model = UsageModel(defaults: defaults)
        let store = ProviderStore(codex: model, defaults: defaults)
        store.setLanguage(language)
        store.appearance.motion = .off
        defer { store.stop() }
        let controller = MonitorSettingsHostingController(rootView: MonitorSettingsView(model: model, store: store),
            quotaController: MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {})))
        let host = try #require(controller.view as? SettingsHostingView)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func rows(_ view: NSView) -> [SettingsRowButton] {
            (view as? SettingsRowButton).map { [$0] } ?? view.subviews.flatMap(rows)
        }
        let buttons = rows(host)
        #expect(buttons.count == MonitorSettingsSection.allCases.count)
        for section in MonitorSettingsSection.allCases {
            let button = try #require(buttons.first { $0.identifier?.rawValue == "settings-navigation-" + section.symbol })
            #expect(abs(button.bounds.width - (language == .english ? 178 : 144)) < 1)
            #expect(button.bounds.height >= 30)
            // Inspect the actual hosting view's native hit test, including blank
            // right edge and padding, rather than dispatching the action by title.
            for local in [NSPoint(x: button.bounds.maxX - 3, y: button.bounds.midY),
                          NSPoint(x: 3, y: 3), NSPoint(x: button.bounds.midX, y: button.bounds.maxY - 3)] {
                let hit = host.hitTest(button.convert(local, to: host.superview))
                let hitsButton = hit === button
                #expect(hitsButton)
            }
            button.performClick(nil)
            for _ in 0..<10 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            #expect((button.accessibilityValue() as? Int) == 1)
            #expect(button.accessibilityLabel() == L10n.text(section.rawValue, language: language))
        }
    }
}
