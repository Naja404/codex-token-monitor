import AppKit
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Suite(.serialized) @MainActor
struct ApplicationMenuTests {
    @Test(arguments: [false, true])
    func commandPasteReachesProviderTextAndSecureFields(secure: Bool) throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let clipboard = ClipboardSnapshot()
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
            clipboard.restore()
        }
        let name = "shortcut-fields-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/test/missing-agy", forKey: "antigravityCLIPath")
        let model = UsageModel(defaults: defaults)
        let store = ProviderStore(codex: model, defaults: defaults)
        defer { store.stop() }
        let view = secure
            ? AnyView(WarpProviderSettings(store: store, expanded: true).padding(16))
            : AnyView(MonitorSettingsView(model: model, store: store, expandedProviders: [.antigravity]))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        ApplicationMenu.install(language: .english)
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(fields)
        }
        let field = try #require(fields(host).first { ($0 is NSSecureTextField) == secure })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let menu = try #require(NSApp.mainMenu)
        // A SwiftPM test host has no running foreground app/key window. Route to its
        // real field editor explicitly; production items retain nil responder-chain targets.
        for item in menu.items.flatMap({ $0.submenu?.items ?? [] }) where ["v", "a", "c", "x"].contains(item.keyEquivalent) {
            #expect(item.target == nil)
            item.target = editor
        }
        editor.selectAll(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("shortcut-test-value", forType: .string)
        let paste = try command("v", keyCode: 9, window: window)
        #expect(!NSMenu().performKeyEquivalent(with: paste))
        #expect(menu.performKeyEquivalent(with: paste))
        #expect(editor.string == "shortcut-test-value")
        #expect(menu.performKeyEquivalent(with: try command("a", keyCode: 0, window: window)))
        #expect(editor.selectedRange().length == "shortcut-test-value".utf16.count)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("clipboard-sentinel", forType: .string)
        _ = menu.performKeyEquivalent(with: try command("c", keyCode: 8, window: window))
        // Native secure fields must keep their normal protection against copying secrets.
        #expect(NSPasteboard.general.string(forType: .string) == (secure ? "clipboard-sentinel" : "shortcut-test-value"))
        _ = menu.performKeyEquivalent(with: try command("x", keyCode: 7, window: window))
        #expect(NSPasteboard.general.string(forType: .string) == (secure ? "clipboard-sentinel" : "shortcut-test-value"))
        #expect(editor.string == (secure ? "shortcut-test-value" : ""))
    }

    @Test func commandWClosesAndCanReopenTheActualSettingsWindow() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        ApplicationMenu.install(language: .english)
        let delegate = AppDelegate()
        let window = delegate.makeSettingsWindow()
        defer { window.close() }
        let menu = try #require(NSApp.mainMenu)
        let close = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "w" })
        #expect(close.target == nil)
        close.target = window
        window.orderFront(nil)
        #expect(window.isVisible)
        #expect(menu.performKeyEquivalent(with: try command("w", keyCode: 13, window: window)))
        #expect(!window.isVisible)
        window.orderFront(nil)
        #expect(window.isVisible)
        #expect(menu.performKeyEquivalent(with: try command("w", keyCode: 13, window: window)))
        #expect(!window.isVisible)
    }

    @Test func menusUseResponderChainAndTranslateWithoutChangingKeyBindings() throws {
        let chinese = ApplicationMenu.make(language: .simplifiedChinese)
        let english = ApplicationMenu.make(language: .english)
        let cnItems = chinese.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }
        let enItems = english.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }
        #expect(cnItems.map(\.keyEquivalent) == enItems.map(\.keyEquivalent))
        #expect(enItems.allSatisfy { $0.target == nil })
        #expect(enItems.first { $0.keyEquivalent == "v" }?.title == "Paste")
        #expect(enItems.first { $0.keyEquivalent == "w" }?.title == "Close Window")
        #expect(enItems.first { $0.title == "Redo" }?.keyEquivalentModifierMask == [.command, .shift])
    }

    private func command(_ key: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
    }

}

@MainActor private struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]] = (NSPasteboard.general.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
    }
    func restore() {
        NSPasteboard.general.clearContents()
        let copies = items.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(copies)
    }
}
