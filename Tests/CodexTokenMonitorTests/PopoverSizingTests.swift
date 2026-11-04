import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Suite(.serialized) @MainActor
struct PopoverSizingTests {
    @Test(arguments: [MonitorTheme.native, .liquidGlass], [MonitorMotion.gentle, .off])
    func livePopoverResizesThroughIntermediateHeights(theme: MonitorTheme, motion: MonitorMotion) async throws {
        _ = NSApplication.shared
        let name = "popover-motion-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = UsageModel(defaults: defaults, readUsage: {
            .init(primary: .init(usedPercent: 20, resetsAt: 1_800_000_000),
                  secondary: .init(usedPercent: 35, resetsAt: 1_800_000_000), planName: "Pro", additional: [])
        })
        let store = ProviderStore(codex: model, defaults: defaults)
        store.appearance.theme = theme
        store.appearance.mode = theme == .native ? .light : .dark
        store.appearance.motion = motion
        defer { store.stop() }
        store.beginPopover()
        model.refresh()
        let controller = MonitorHostingController(rootView: MonitorView(model: model, store: store, onQuit: {}, onSettings: {}))
        controller.rootView.viewportHeight = 500
        let anchor = NSButton(title: "Motion preview", target: nil, action: nil)
        let window = NSWindow(contentRect: .init(x: 200, y: 500, width: 100, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.close() }
        let popover = ResizeRecordingPopover()
        popover.animates = true
        controller.onContentSizeChange = { [weak popover] size in popover?.resizeWithContent(size) }
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        defer { popover.close() }
        func frame() {
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
        }
        for _ in 0..<20 { frame(); try await Task.sleep(for: .milliseconds(15)) }
        // A command-line test runner cannot become a foreground app. Deliver the
        // same activation event as the menu-bar app so its gentle motion is enabled.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for _ in 0..<5 { frame(); try await Task.sleep(for: .milliseconds(15)) }
        var previewFrames: [CGImage] = []
        let previewDirectory = ProcessInfo.processInfo.environment["POPOVER_MOTION_PREVIEW_DIR"]
        func sample(_ count: Int = 30) async throws -> [CGFloat] {
            var heights: [CGFloat] = []
            for _ in 0..<count {
                frame()
                heights.append(popover.contentSize.height)
                if previewDirectory != nil {
                    let view = controller.view
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let image = bitmap.cgImage { previewFrames.append(image) }
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            return heights
        }
        func intermediateCount(_ heights: [CGFloat], low: CGFloat, high: CGFloat) -> Int {
            Set(heights.filter { $0 > low + 1 && $0 < high - 1 }.map { Int($0) }).count
        }
        let collapsed = popover.contentSize.height
        store.toggleProviderDetails(.codex)
        let opening = try await sample()
        let expanded = popover.contentSize.height
        #expect(expanded > collapsed + 40 && expanded <= 500)
        let openingSteps = intermediateCount(opening, low: collapsed, high: expanded)
        // Optional bitmap capture is much slower than a display frame, especially
        // for live glass material; it is a visual preview, not a frame-rate probe.
        let minimumSteps = previewDirectory == nil ? 3 : 1
        #expect(motion == .gentle ? openingSteps >= minimumSteps : openingSteps == 0)
        #expect(zip(opening, opening.dropFirst()).allSatisfy { $1 >= $0 - 1 })
        store.toggleProviderDetails(.codex)
        let closing = try await sample()
        #expect(abs(popover.contentSize.height - collapsed) <= 1)
        let closingSteps = intermediateCount(closing, low: collapsed, high: expanded)
        #expect(motion == .gentle ? closingSteps >= 2 : closingSteps == 0)
        #expect(zip(closing, closing.dropFirst()).allSatisfy { $1 <= $0 + 1 })
        // Reverse an in-flight expansion: it must finish collapsed without a
        // delayed native window resize or a stale expanded viewport.
        store.toggleProviderDetails(.codex)
        _ = try await sample(4)
        store.toggleProviderDetails(.codex)
        _ = try await sample(20)
        #expect(abs(popover.contentSize.height - collapsed) <= 1)
        #expect(popover.animates, "Keep the native opening/closing animation setting")
        #expect(!popover.resizeAnimationFlags.isEmpty)
        #expect(popover.resizeAnimationFlags.allSatisfy { !$0 }, "Disclosure frames must not start a second AppKit animation")
        print("Popover \(theme.rawValue)/\(motion.rawValue): \(openingSteps) opening, \(closingSteps) closing intermediate heights")
        if let directory = previewDirectory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("popover-\(theme.rawValue)-\(motion.rawValue).gif")
            let gif = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, previewFrames.count, nil))
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for image in previewFrames {
                let canvas = try #require(CGContext(data: nil, width: 720, height: 1000, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                canvas.setFillColor(NSColor.windowBackgroundColor.cgColor)
                canvas.fill(.init(x: 0, y: 0, width: 720, height: 1000))
                let height = 720 * CGFloat(image.height) / CGFloat(image.width)
                canvas.draw(image, in: .init(x: 0, y: 1000 - height, width: 720, height: height))
                CGImageDestinationAddImage(gif, try #require(canvas.makeImage()),
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.03]] as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(gif))
        }
    }

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
        controller.onContentSizeChange = { [weak popover] size in popover?.resizeWithContent(size) }
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

@MainActor private final class ResizeRecordingPopover: NSPopover {
    var resizeAnimationFlags: [Bool] = []
    override var contentSize: NSSize {
        willSet { if isShown { resizeAnimationFlags.append(animates) } }
    }
}
