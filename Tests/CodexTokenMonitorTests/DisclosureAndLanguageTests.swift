import Foundation
import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Test func disclosureMotionHonorsExistingMotionPolicy() {
    for expanded in [true, false] {
        #expect(MonitorStyle(motionEnabled: true).disclosureAnimation(expanded: expanded) != nil)
        #expect(MonitorStyle(motionEnabled: false).disclosureAnimation(expanded: expanded) == nil)
    }
}

@Test @MainActor func disclosureLayoutRevealsWithoutCompressingContent() {
    _ = NSApplication.shared
    for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let host = NSHostingView(rootView: DisclosureLayout(progress: progress) {
            Color.blue.frame(width: 200, height: 120)
        })
        #expect(abs(host.fittingSize.height - 120 * progress) < 1)
        #expect(abs(host.fittingSize.width - 200) < 1)
    }
}

@Test @MainActor func quotaCardsStartCollapsedAndExpandIndependently() throws {
    let name = "disclosure-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "antigravityEnabled")
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(store.expandedProviders.isEmpty)
    store.toggleProviderDetails(.codex)
    #expect(store.expandedProviders == [.codex])
    #expect(!store.allProviderDetailsExpanded)
    store.toggleAllProviderDetails()
    #expect(store.expandedProviders == [.codex, .antigravity])
    #expect(store.allProviderDetailsExpanded)
    store.toggleProviderDetails(.codex)
    #expect(!store.allProviderDetailsExpanded)
    store.toggleAllProviderDetails()
    store.toggleAllProviderDetails()
    #expect(store.expandedProviders.isEmpty)
    store.toggleAllProviderDetails()
    store.beginPopover()
    #expect(store.expandedProviders.isEmpty)
    store.setCodexEnabled(false)
    store.setAntigravityEnabled(false)
    store.toggleAllProviderDetails()
    #expect(!store.allProviderDetailsExpanded)
    #expect(store.expandedProviders.isEmpty)
}

@Test @MainActor func languageAndRotationPresetsPersistWithoutFetching() throws {
    let name = "language-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(store.language == .simplifiedChinese)
    store.setLanguage(.english)
    #expect(ProviderStore.rotationPresets == [10, 30, 60])
    for seconds in ProviderStore.rotationPresets {
        store.setMenuRotationInterval(seconds)
        let restored = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
        #expect(restored.menuRotationInterval == seconds)
        #expect(restored.language == .english)
        #expect(restored.codex.lastRefreshAt == nil)
    }
    #expect(L10n.text("全部展开", language: .english) == "Expand all")
    #expect(L10n.text("全部展开", language: .simplifiedChinese) == "全部展开")
    #expect(L10n.format("每 %d 秒切换", 30, language: .english) == "Switch every 30 seconds")
    #expect(store.menuLines.first.hasPrefix("5h"))
    #expect(store.menuLines.second.hasPrefix("7d"))
    store.setLanguage(.simplifiedChinese)
    #expect(store.menuLines.first.hasPrefix("5小时"))
    #expect(store.codex.lastRefreshAt == nil)
}

@Test func englishCatalogContainsAllLocalizedLiteralKeysAndMatchingPlaceholders() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
    let keyPattern = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\("((?:[^"\\]|\\.)*)""#)
    let placeholderPattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@df]"#)
    func placeholders(_ text: String) -> [String] {
        placeholderPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }.sorted()
    }
    for file in sources where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in keyPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let literal = String(source[Range(match.range(at: 1), in: source)!])
            let key = try JSONDecoder().decode(String.self, from: Data(("\"" + literal + "\"").utf8))
            let translation = try #require(L10n.english[key], "Missing translation: \(key)")
            #expect(placeholders(key) == placeholders(translation))
        }
    }
    #expect(!L10n.english.isEmpty)
}

@MainActor private final class DisclosureDraft: ObservableObject {
    @Published var expanded = true
    @Published var text = "unsaved-test-value"
}

private struct DisclosureDraftView: View {
    @ObservedObject var draft: DisclosureDraft
    var body: some View {
        SettingsDisclosure(title: "Connection", expanded: $draft.expanded) {
            TextField("Draft", text: $draft.text)
        }.padding(12)
    }
}

// Rendering tests share AppKit's main run loop; serialize them so GIF encoding
// cannot stall another test's animation sampling.
@Suite(.serialized) struct DisclosureMotionTests {
    @Test(arguments: [true, false])
    @MainActor func refreshHighlightDoesNotMoveCardsIndependentlyOfDisclosure(motionEnabled: Bool) async throws {
        _ = NSApplication.shared
        let state = DisclosureRefreshState()
        let style = MonitorStyle(theme: .graphite, dark: true, solid: true, motionEnabled: motionEnabled)
        let host = NSHostingView(rootView: DisclosureRefreshFixture(state: state)
            .frame(width: 320, height: 800, alignment: .top)
            .background(Color(nsColor: style.palette.background))
            .environment(\.monitorStyle, style))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func snapshot() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let initial = try snapshot()
        let scale = Double(initial.pixelsWide) / 320
        let target = try #require(initial.colorAt(x: Int(17 * scale), y: Int(32 * scale))?.usingColorSpace(.deviceRGB))
        var violations: [String] = []
        for frame in 0..<70 {
            if frame == 2 || (10...46).contains(frame) && frame.isMultiple(of: 3) { state.expanded.toggle() }
            if [3, 13, 23, 33, 43].contains(frame) { state.successAt = Date() }
            let rep = try snapshot()
            var edges: [ClosedRange<Double>] = []
            var start: Int?
            for y in 0...rep.pixelsHigh {
                let color = y < rep.pixelsHigh ? rep.colorAt(x: Int(17 * scale), y: y)?.usingColorSpace(.deviceRGB) : nil
                let matches = color.map {
                    abs($0.redComponent - target.redComponent) + abs($0.greenComponent - target.greenComponent)
                        + abs($0.blueComponent - target.blueComponent) < 0.04
                } ?? false
                if matches { if start == nil { start = y } }
                else if let first = start {
                    if Double(y - first) / scale > 30 { edges.append(Double(first) / scale...Double(y - 1) / scale) }
                    start = nil
                }
            }
            let gaps = zip(edges, edges.dropFirst()).map { $1.lowerBound - $0.upperBound }
            if edges.count != 3 || gaps.contains(where: { $0 < 8 }) {
                violations.append("frame \(frame): edges \(edges), gaps \(gaps)")
                if violations.count == 1, let directory = ProcessInfo.processInfo.environment["DISCLOSURE_PREVIEW_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("refresh-overlap-minimal.png"))
                }
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(violations.isEmpty, "\(violations.prefix(6))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISCLOSURE_PREVIEW_DIR"] != nil), arguments: [540.0, 2000.0])
    @MainActor func allProviderCardsCollapseTogetherWithoutDelayedLayout(viewportHeight: Double) async throws {
        _ = NSApplication.shared
        let name = "disclosure-batch-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for provider in ["antigravity", "claude", "warp", "teamo"] {
            defaults.set(true, forKey: provider + "Enabled")
        }
        let model = UsageModel(defaults: defaults, readUsage: {
            LiveRateLimits(primary: .init(usedPercent: 23, resetsAt: 1_792_000_000),
                           secondary: .init(usedPercent: 62, resetsAt: 1_792_500_000), planName: "Pro", additional: [])
        })
        let store = ProviderStore(codex: model, defaults: defaults, readAntigravity: { _ in
            .init(installation: .init(path: "/preview/agy", version: "1.3.2"),
                  groups: try AntigravityReport.parse(antigravityFixture))
        }, readClaude: { _ in
            .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max")
        }, readWarp: { _ in
            try WarpUsageSnapshot.parse(Data(warpFixture.utf8))
        }, readTeamo: { _ in try teamoFixture() })
        defer { store.stop() }
        store.refreshAll()
        for _ in 0..<200 {
            if model.rateLimitStatus == .live && !store.isRefreshingAntigravity && !store.isRefreshingClaude
                && !store.isRefreshingWarp && !store.isRefreshingTeamo { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.rateLimitStatus == .live)
        #expect(store.antigravityGroups.count == 2)
        #expect(store.claudeMetrics.count > 0)
        #expect(store.warpSnapshot != nil && store.teamoSnapshot != nil)
        let style = MonitorStyle(theme: .graphite, dark: true, solid: true, motionEnabled: true)
        let host = NSHostingView(rootView: ScrollView {
            ProviderSummaryView(model: model, store: store).padding(12)
        }.frame(width: 360, height: viewportHeight, alignment: .top)
            .background(Color(nsColor: style.palette.background))
            .environment(\.monitorStyle, style).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: viewportHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // Sample the blank inner edge of each real card, not its text/chevron. This
        // detects delayed or jumping card bounds even when the text fades correctly.
        func heights() throws -> [Double] {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = Double(rep.pixelsWide) / 360
            let target = try #require(rep.colorAt(x: Int(20 * scale), y: Int(40 * scale))?.usingColorSpace(.deviceRGB))
            var runs: [Double] = []
            var length = 0
            for y in 0..<rep.pixelsHigh {
                let color = try #require(rep.colorAt(x: Int(20 * scale), y: y)?.usingColorSpace(.deviceRGB))
                let distance = abs(color.redComponent - target.redComponent)
                    + abs(color.greenComponent - target.greenComponent) + abs(color.blueComponent - target.blueComponent)
                if distance < 0.04 { length += 1 }
                else {
                    if Double(length) / scale > 30 { runs.append(Double(length) / scale) }
                    length = 0
                }
            }
            return runs
        }
        let collapsed = try heights()
        #expect(collapsed.count == 5)
        store.toggleAllProviderDetails()
        _ = try heights()
        try await Task.sleep(for: .milliseconds(600))
        let expanded = try heights()
        store.toggleAllProviderDetails()
        _ = try heights()
        try await Task.sleep(for: .milliseconds(90))
        let midway = try heights()
        let progress = zip(zip(expanded, collapsed), midway).map { pair, current in
            (pair.0 - current) / (pair.0 - pair.1)
        }
        if viewportHeight == 2000 {
            #expect(progress.count == 5)
            #expect(progress.allSatisfy { $0 > 0.05 && $0 < 0.98 })
            #expect((progress.max() ?? 1) - (progress.min() ?? 0) < 0.15)
        }
        try await Task.sleep(for: .milliseconds(150))
        let settled = try heights()
        #expect(settled.count == 5)
        #expect(zip(settled, collapsed).allSatisfy { abs($0 - $1) <= 1 })

        // Reverse a batch expansion in flight: no queued close or lingering cards.
        store.toggleAllProviderDetails()
        _ = try heights()
        try await Task.sleep(for: .milliseconds(60))
        _ = try heights()
        store.toggleAllProviderDetails()
        _ = try heights()
        try await Task.sleep(for: .milliseconds(250))
        let interrupted = try heights()
        #expect(interrupted.count == 5)
        #expect(zip(interrupted, collapsed).allSatisfy { abs($0 - $1) <= 1 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISCLOSURE_PREVIEW_DIR"] != nil))
    @MainActor func rendersLiveDisclosureMotionAndInterruption() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DISCLOSURE_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for motion in [true, false] {
            let draft = DisclosureDraft()
            draft.expanded = false
            let host = NSHostingView(rootView: DisclosureDraftView(draft: draft)
                .frame(width: 400, height: 180, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.monitorStyle, MonitorStyle(motionEnabled: motion)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func snapshot() throws -> CGImage {
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                return try #require(rep.cgImage)
            }
            _ = try snapshot()
            try await Task.sleep(for: .milliseconds(50))
            let url = directory.appendingPathComponent("disclosure-\(motion ? "gentle" : "off").gif")
            let gif = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 60, nil))
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            var openingFrames = Set<Data>()
            for frame in 0..<60 {
                if frame == 5 || frame == 35 { draft.expanded = true }
                if frame == 25 || frame == 38 { draft.expanded = false }
                let image = try snapshot()
                // Exclude the right-hand chevron: content itself must animate, not only the icon.
                if (6..<20).contains(frame),
                   let content = image.cropping(to: CGRect(x: 0, y: 0, width: image.width * 3 / 4, height: image.height)),
                   let pixels = content.dataProvider?.data { openingFrames.insert(pixels as Data) }
                if [0, 8, 20, 29, 50].contains(frame) {
                    let pngURL = directory.appendingPathComponent("\(motion ? "gentle" : "off")-\(frame).png")
                    let png = try #require(CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(png, image, nil)
                    #expect(CGImageDestinationFinalize(png))
                }
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.03]] as CFDictionary)
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(CGImageDestinationFinalize(gif))
            // Detect actual intermediate rendered frames, not just an animation declaration.
            #expect(motion ? openingFrames.count > 2 : openingFrames.count == 1)
            #expect(!draft.expanded)
            #expect(draft.text == "unsaved-test-value")
        }
    }

}

@MainActor private final class DisclosureRefreshState: ObservableObject {
    @Published var expanded = false
    @Published var successAt: Date?
}

private struct DisclosureRefreshFixture: View {
    @ObservedObject var state: DisclosureRefreshState
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<3) { index in
                VStack(spacing: 0) {
                    Color.white.frame(height: 30)
                    DisclosureContent(expanded: state.expanded) {
                        Color.black.frame(height: [120.0, 240.0, 80.0][index])
                    }
                }.padding(8).monitorSurface(successAt: index == 1 ? nil : state.successAt)
            }
        }.padding(12)
    }
}

@Test @MainActor func settingsDisclosurePreservesDraftAndDisablesHiddenInputs() async throws {
    _ = NSApplication.shared
    let draft = DisclosureDraft()
    let host = NSHostingView(rootView: DisclosureDraftView(draft: draft))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    func field(_ view: NSView) -> NSTextField? {
        if let value = view as? NSTextField, value.isEditable { return value }
        return view.subviews.compactMap { field($0) }.first
    }
    host.layoutSubtreeIfNeeded()
    #expect(try #require(field(host)).stringValue == "unsaved-test-value")
    draft.expanded = false
    try await Task.sleep(for: .milliseconds(20))
    host.layoutSubtreeIfNeeded()
    #expect(!(try #require(field(host))).isEnabled)
    draft.expanded = true
    try await Task.sleep(for: .milliseconds(20))
    host.layoutSubtreeIfNeeded()
    #expect(try #require(field(host)).isEnabled)
    #expect(try #require(field(host)).stringValue == "unsaved-test-value")
}
