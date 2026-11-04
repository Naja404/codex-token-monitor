import AppKit
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Suite(.serialized) @MainActor
struct PopoverSizingTests {
    @Test(arguments: [MonitorTheme.native, .liquidGlass], [MonitorColorMode.light, .dark])
    func livePopoverFitsContentAndScrollsAtHalfScreen(theme: MonitorTheme, mode: MonitorColorMode) async throws {
        _ = NSApplication.shared
        let name = "popover-sizing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = UsageModel(defaults: defaults, readUsage: {
            .init(primary: .init(usedPercent: 20, resetsAt: 1_800_000_000),
                  secondary: .init(usedPercent: 35, resetsAt: 1_800_000_000), planName: "Pro", additional: [])
        })
        let store = ProviderStore(codex: model, defaults: defaults,
            readAntigravity: { _ in throw ProviderReadError.invalidResponse },
            readClaude: { _ in throw ProviderReadError.invalidResponse },
            readWarp: { _ in throw ProviderReadError.invalidResponse },
            readTeamo: { _ in throw ProviderReadError.invalidResponse })
        defer { store.stop() }
        let language: AppLanguage = mode == .light ? .simplifiedChinese : .english
        store.appearance.theme = theme
        store.appearance.mode = mode
        store.appearance.motion = .off
        store.setLanguage(language)
        model.refresh()
        let controller = MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
        controller.rootView.viewportHeight = 500
        let anchor = NSButton(title: "Preview", target: nil, action: nil)
        let window = NSWindow(contentRect: .init(x: 200, y: 500, width: 100, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.close() }
        let popover = NSPopover()
        popover.animates = false
        controller.onContentSizeChange = { [weak popover] size in popover?.contentSize = size }
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        defer { popover.close() }

        func settle() async throws -> CGFloat {
            for _ in 0..<20 {
                controller.view.layoutSubtreeIfNeeded()
                controller.view.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(abs(popover.contentSize.width - 360) < 1)
            #expect(abs(popover.contentSize.height - controller.preferredContentSize.height) < 1)
            return popover.contentSize.height
        }
        func preview(_ label: String) throws {
            guard let path = ProcessInfo.processInfo.environment["POPOVER_PREVIEW_DIR"] else { return }
            let dir = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let view = controller.view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(theme.rawValue)-\(language.rawValue)-\(label).png"))
        }
        let single = try await settle()
        #expect(single > 200 && single < 350)
        try preview("single")
        store.toggleProviderDetails(.codex)
        let expanded = try await settle()
        #expect(expanded > single && expanded <= 500)
        store.toggleProviderDetails(.codex)
        #expect(abs(try await settle() - single) < 1)
        store.setAntigravityEnabled(true)
        store.setWarpEnabled(true)
        let three = try await settle()
        #expect(three > single && three <= 500)
        try preview("three")
        store.setClaudeEnabled(true)
        store.setTeamoEnabled(true)
        store.toggleAllProviderDetails()
        #expect(abs(try await settle() - 500) < 1)
        try preview("expanded")
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: controller.view))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        let before = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: .init(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y != before)
        // A smaller display updates the cap without replacing the controller or Touch Bar.
        controller.rootView.viewportHeight = 300
        #expect(abs(try await settle() - 300) < 1)
        store.toggleAllProviderDetails()
        store.setAntigravityEnabled(false)
        store.setClaudeEnabled(false)
        store.setWarpEnabled(false)
        store.setTeamoEnabled(false)
        #expect(abs(try await settle() - single) < 1)
        store.setCodexEnabled(false)
        let empty = try await settle()
        #expect(empty > 200 && empty <= 300)
        try preview("empty")
    }
}
