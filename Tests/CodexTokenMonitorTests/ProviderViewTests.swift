import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import CodexTokenMonitor

@Test(.enabled(if: ProcessInfo.processInfo.environment["ARGON_PREVIEW_DIR"] != nil))
@MainActor func rendersIndependentArgonQuota() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARGON_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "argon-preview-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "codexEnabled")
    defaults.set(true, forKey: "antigravityEnabled")
    let model = UsageModel(defaults: defaults)
    let groups = try AntigravityReport.parse(antigravityFixture) +
        AntigravityReport.parse(antigravityArgonFixture).filter { $0.id == "gemini-argon" }
    let store = ProviderStore(codex: model, defaults: defaults, readAntigravity: { _ in
        try await Task.sleep(for: .milliseconds(50))
        return .init(installation: .init(path: "/preview/agy", version: "1.4.7"), groups: groups)
    })
    defer { store.stop() }
    store.appearance.motion = .off
    store.refreshAntigravity()
    for _ in 0..<200 where store.isRefreshingAntigravity { try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.antigravityGroups.count == 3)
    for (label, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
        try capture(ProviderSummaryView(model: model, store: store).padding(12)
            .modifier(MonitorThemeScope(appearance: store.appearance)).environment(\.colorScheme, scheme),
                    size: .init(width: 360, height: 240), url: directory.appendingPathComponent("argon-\(label).png"))
    }
    store.setMenuSource(.antigravityArgon)
    store.refreshAntigravity()
    #expect(store.menuLines.second.contains("44%"))
    try capture(ProviderSummaryView(model: model, store: store).padding(12)
        .modifier(MonitorThemeScope(appearance: store.appearance)).environment(\.colorScheme, .light),
                size: .init(width: 360, height: 240), url: directory.appendingPathComponent("argon-refreshing.png"))
    let frames = ["argon-light.png", "argon-refreshing.png", "argon-light.png"]
    let gif = try #require(CGImageDestinationCreateWithURL(
        directory.appendingPathComponent("argon-refresh-stable.gif") as CFURL,
        "com.compuserve.gif" as CFString, frames.count, nil))
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in frames {
        let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent(frame) as CFURL, nil))
        CGImageDestinationAddImage(gif, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.5]
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(gif))
}

@Test(arguments: [MonitorTheme.native, .liquidGlass])
@MainActor func settingsCLIFieldCanBecomeFirstResponder(theme: MonitorTheme) throws {
    _ = NSApplication.shared
    let name = "provider-focus-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("/test/missing-agy", forKey: "antigravityCLIPath")
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults)
    store.appearance.theme = theme
    defer { store.stop() }
    let host = NSHostingView(rootView: MonitorSettingsView(model: model, store: store, expandedProviders: [.antigravity]))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    func editableFields(in view: NSView) -> [NSTextField] {
        let fields = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return fields + view.subviews.flatMap { editableFields(in: $0) }
    }
    let field = try #require(editableFields(in: host).first)
    #expect(field.acceptsFirstResponder)
    #expect(window.makeFirstResponder(field))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"] != nil))
@MainActor func rendersProviderViews() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "provider-preview-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "antigravityEnabled")
    defaults.set(true, forKey: "claudeEnabled")
    defaults.set(true, forKey: "warpEnabled")
    defaults.set(true, forKey: "teamoEnabled")
    defaults.set("/preview/agy", forKey: "antigravityCLIPath")
    let model = UsageModel(defaults: defaults, readUsage: {
        LiveRateLimits(primary: .init(usedPercent: 23, resetsAt: 1_792_000_000),
                       secondary: .init(usedPercent: 62, resetsAt: 1_792_500_000),
                       planName: "Pro · 示例", additional: [])
    })
    let store = ProviderStore(codex: model, defaults: defaults, readAntigravity: { _ in
        AntigravitySnapshot(installation: .init(path: "/preview/agy", version: "1.3.2"),
                           groups: try AntigravityReport.parse(antigravityFixture))
    }, readClaude: { _ in
        .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max · 示例")
    }, readWarp: { _ in
        try WarpUsageSnapshot.parse(Data(warpFixture.utf8))
    }, readTeamo: { _ in
        let example = try teamoFixture()
        return .init(balance: example.balance, cost: example.cost, currency: example.currency,
                     totalTokens: example.totalTokens, requests: example.requests,
                     start: Int64(Calendar.current.startOfDay(for: .now).timeIntervalSince1970),
                     end: Int64(Date().timeIntervalSince1970))
    })
    defer { store.stop() }
    store.refreshAll()
    for _ in 0..<200 {
        if !store.isRefreshingAntigravity && !store.isRefreshingClaude && !store.isRefreshingWarp && !store.isRefreshingTeamo && model.rateLimitStatus == .live { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.rateLimitStatus == .live)
    #expect(store.antigravityGroups.count == 2)
    #expect(store.teamoSnapshot != nil)
    store.setMenuRotationEnabled(true)
    // L10n.current reads standard defaults; fixtures otherwise use an isolated suite.
    // This rendering section is synchronous, and always restores the original value.
    let originalLanguage = UserDefaults.standard.object(forKey: "monitorLanguage")
    defer { UserDefaults.standard.set(originalLanguage, forKey: "monitorLanguage") }
    UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: "monitorLanguage")
    for (label, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
        store.beginPopover()
        try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}).environment(\.colorScheme, scheme),
                    size: NSSize(width: 360, height: 540), url: directory.appendingPathComponent("overview-\(label).png"))
        store.toggleAllProviderDetails()
        try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}).environment(\.colorScheme, scheme),
                    size: NSSize(width: 360, height: 540), url: directory.appendingPathComponent("details-\(label).png"))
        try capture(WarpProviderSettings(store: store, expanded: true).padding(16)
            .frame(width: 520, height: 380, alignment: .top)
            .background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance))
            .environment(\.colorScheme, scheme),
                    size: NSSize(width: 520, height: 380), url: directory.appendingPathComponent("warp-settings-\(label).png"))
        try capture(MonitorSettingsView(model: model, store: store).environment(\.colorScheme, scheme),
                    size: NSSize(width: 740, height: 600), url: directory.appendingPathComponent("settings-\(label).png"))
        try capture(MonitorSettingsView(model: model, store: store, initialSection: .display).environment(\.colorScheme, scheme),
                    size: NSSize(width: 740, height: 600), url: directory.appendingPathComponent("rotation-\(label).png"))
    }
    for theme in MonitorTheme.allCases {
        store.appearance.theme = theme
        for mode in [MonitorColorMode.light, .dark] {
            store.appearance.mode = mode
            store.beginPopover()
            try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                        size: .init(width: 360, height: 540), url: directory.appendingPathComponent("theme-\(theme.rawValue)-\(mode.rawValue).png"))
            store.toggleAllProviderDetails()
            try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                        size: .init(width: 360, height: 540), url: directory.appendingPathComponent("theme-\(theme.rawValue)-\(mode.rawValue)-details.png"))
            try capture(MonitorSettingsView(model: model, store: store, initialSection: .appearance),
                        size: .init(width: 740, height: 800), url: directory.appendingPathComponent("appearance-\(theme.rawValue)-\(mode.rawValue).png"))
            if theme == .liquidGlass {
                store.setLanguage(.english)
                UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: "monitorLanguage")
                try capture(MonitorSettingsView(model: model, store: store, initialSection: .appearance),
                            size: .init(width: 740, height: 800), url: directory.appendingPathComponent("glass-settings-english-\(mode.rawValue).png"))
                store.setLanguage(.simplifiedChinese)
                UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: "monitorLanguage")
                try capture(MonitorPanel(model: model, store: store, onQuit: {}, onSettings: {}, viewportHeight: 540)
                    .environment(\.monitorStyle, MonitorStyle(theme: .liquidGlass, dark: mode == .dark,
                                                             solid: true, highContrast: true))
                    .environment(\.colorScheme, mode == .dark ? .dark : .light),
                            size: .init(width: 360, height: 540), url: directory.appendingPathComponent("glass-accessible-\(mode.rawValue).png"))
            }
        }
    }
    store.appearance.theme = .aurora
    store.beginPopover()
    // Render the resolved accessibility style without changing macOS user preferences.
    try capture(MonitorPanel(model: model, store: store, onQuit: {}, onSettings: {}, viewportHeight: 540)
        .environment(\.monitorStyle, MonitorStyle(theme: .aurora, dark: true, solid: true, highContrast: true, motionEnabled: false))
        .environment(\.colorScheme, .dark),
                size: .init(width: 360, height: 540), url: directory.appendingPathComponent("theme-accessible.png"))

    // A reproducible native-view walkthrough, not a recording of a real account.
    let gifURL = directory.appendingPathComponent("providers-walkthrough.gif")
    let frames: [(MonitorTheme, Bool, MenuQuotaSource)] = [
        (.native, false, .codex), (.native, false, .teamo),
        (.aurora, true, .teamo), (.graphite, false, .warp),
        (.liquidGlass, false, .codex), (.liquidGlass, true, .codex)
    ]
    let destination = try #require(CGImageDestinationCreateWithURL(
        gifURL as CFURL, "com.compuserve.gif" as CFString, frames.count, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    store.appearance.mode = .dark
    store.appearance.motion = .off
    for (theme, mode, source) in frames {
        store.appearance.theme = theme
        store.beginPopover()
        if mode { store.toggleAllProviderDetails() }
        store.setMenuSource(source)
        let view = VStack(spacing: 0) {
            HStack {
                Text(mode ? "示例数据 · 展开" : "示例数据 · 折叠").font(.caption)
                Spacer()
                VStack(spacing: 0) {
                    Text(store.menuLines.first)
                    Text(store.menuLines.second)
                }.font(.system(size: 10, weight: .medium)).monospacedDigit()
            }.padding(.horizontal, 14).frame(height: 44)
                .background(Color(nsColor: .darkGray)).foregroundStyle(.white)
            MonitorView(model: model, store: store, onQuit: {}, onSettings: {})
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 584)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        CGImageDestinationAddImage(destination, try #require(bitmap.cgImage), [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 2.5]
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == frames.count)
}

@Test @MainActor func bundledProviderLogosAreReadable() {
    for brand in ProviderBrand.allCases {
        #expect(brand.image != nil)
        #expect((brand.image?.size.width ?? 0) > 0)
    }
}

@Test @MainActor func packagedResourcesUseContentsResourcesWithoutBuildDirectoryFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-package-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Monitor.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "test.monitor.resources", "CFBundlePackageType": "APPL"
    ], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: app))
    #expect(ProviderBrand.resourceBundle(in: bundle) == nil)
    let target = resources.appendingPathComponent("CodexTokenMonitor_CodexTokenMonitor.bundle")
    try FileManager.default.copyItem(at: Bundle.module.bundleURL, to: target)
    let loaded = try #require(ProviderBrand.resourceBundle(in: bundle))
    #expect(loaded.bundleURL.standardizedFileURL == target.standardizedFileURL)
    for brand in ProviderBrand.allCases {
        #expect(loaded.url(forResource: brand.rawValue, withExtension: "png") != nil)
    }
}

@Test @MainActor func warpSecureFieldCanBecomeFirstResponder() throws {
    _ = NSApplication.shared
    let name = "warp-focus-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    defer { store.stop() }
    let host = NSHostingView(rootView: WarpProviderSettings(store: store, expanded: true))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    func secureFields(_ view: NSView) -> [NSSecureTextField] {
        (view as? NSSecureTextField).map { [$0] } ?? view.subviews.flatMap { secureFields($0) }
    }
    let field = try #require(secureFields(host).first)
    #expect(window.makeFirstResponder(field))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"] != nil))
@MainActor func rendersEmptyAndFailedProviders() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "provider-empty-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "codexEnabled")
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults, readWarp: { _ in throw WarpReadError.missingKey })
    defer { store.stop() }
    try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                size: .init(width: 360, height: 540), url: directory.appendingPathComponent("empty.png"))
    store.setWarpEnabled(true)
    for _ in 0..<200 where store.isRefreshingWarp { try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.warpError == .missingKey)
    #expect(store.warpSnapshot == nil)
    for mode in [false, true] {
        store.beginPopover()
        if mode { store.toggleAllProviderDetails() }
        try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                    size: .init(width: 360, height: 540), url: directory.appendingPathComponent("failed-\(!mode ? "summary" : "details").png"))
    }
}

@Test @MainActor func teamoConfigurationFieldsCanBecomeFirstResponder() throws {
    _ = NSApplication.shared
    let name = "teamo-focus-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    defer { store.stop() }
    let host = NSHostingView(rootView: TeamoProviderSettings(store: store, expanded: true))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    func fields(_ view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { fields($0) }
    }
    let inputs = fields(host)
    #expect(inputs.count == 2)
    #expect(inputs.contains { $0 is NSSecureTextField })
    for field in inputs { #expect(window.makeFirstResponder(field)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"] != nil))
@MainActor func rendersTeamoSettingsAndCards() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "teamo-preview-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults, readTeamo: { _ in
        let fixture = try teamoFixture()
        return .init(balance: fixture.balance, cost: fixture.cost, currency: fixture.currency,
                     totalTokens: fixture.totalTokens, requests: fixture.requests,
                     start: Int64(Calendar.current.startOfDay(for: .now).timeIntervalSince1970),
                     end: Int64(Date().timeIntervalSince1970))
    })
    defer { store.stop() }
    store.setTeamoEnabled(true)
    for _ in 0..<200 where store.isRefreshingTeamo { try await Task.sleep(for: .milliseconds(5)) }
    for mode in [MonitorColorMode.light, .dark] {
        store.appearance.mode = mode
        try capture(TeamoProviderSettings(store: store, expanded: true).padding(16)
            .frame(width: 500, height: 580, alignment: .top)
            .background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance)),
                    size: .init(width: 500, height: 580), url: directory.appendingPathComponent("teamo-settings-\(mode.rawValue).png"))
        try capture(VStack(spacing: 12) {
            TeamoQuotaCard(store: store)
            TeamoQuotaCard(store: store, detailed: true)
        }.padding(12).frame(width: 360, height: 420, alignment: .top)
            .background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance)),
                    size: .init(width: 360, height: 420), url: directory.appendingPathComponent("teamo-cards-\(mode.rawValue).png"))
    }
}

@MainActor private func capture<V: View>(_ view: V, size: NSSize, url: URL) throws {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NOTIFICATION_PREVIEW_DIR"] != nil))
@MainActor func rendersLocalNotificationSettingsPreview() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOTIFICATION_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "notifications-preview-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = LocalNotificationController(defaults: defaults, getAuthorization: { .allowed },
        requestAuthorization: { true }, send: { _, _ in }, cancelPending: {})
    controller.update { $0.enabled = true; $0.kinds = Set(LocalAlertKind.allCases) }
    await controller.refreshAuthorization()
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    defer { store.stop() }
    try capture(HStack(spacing: 0) {
        SettingsSidebar(selection: .constant(.notifications), language: .simplifiedChinese)
        Divider()
        VStack(alignment: .leading, spacing: 18) {
            Text("通知").font(.title2.weight(.semibold))
            LocalNotificationSettingsView(controller: controller)
            Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }.background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance)),
        size: .init(width: 820, height: 760), url: directory.appendingPathComponent("local-notifications.png"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["UPDATE_PREVIEW_DIR"] != nil))
@MainActor func rendersAboutAndUpdatesPreview() throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["UPDATE_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "about-preview-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = UsageModel(defaults: defaults)
    let store = ProviderStore(codex: model, defaults: defaults)
    defer { store.stop() }
    try capture(HStack(spacing: 0) {
        SettingsSidebar(selection: .constant(.about), language: .simplifiedChinese)
        Divider()
        VStack(alignment: .leading, spacing: 18) {
            Text("关于与更新").font(.title2.weight(.semibold))
            AppAboutView()
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }.background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance)),
        size: .init(width: 740, height: 600), url: directory.appendingPathComponent("settings-updates.png"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INTERACTION_PREVIEW_DIR"] != nil))
@MainActor func rendersDisclosureAndLanguageLayouts() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["INTERACTION_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "interaction-preview-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("/preview/missing-agy", forKey: "antigravityCLIPath")
    defaults.set(true, forKey: "claudeEnabled")
    defaults.set(true, forKey: "teamoEnabled")
    let model = UsageModel(defaults: defaults, readUsage: {
        LiveRateLimits(primary: .init(usedPercent: 23, resetsAt: 1_792_000_000),
                       secondary: .init(usedPercent: 62, resetsAt: 1_792_500_000), planName: "Pro", additional: [])
    })
    let store = ProviderStore(codex: model, defaults: defaults, readClaude: { _ in
        .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max")
    }, readTeamo: { _ in try teamoFixture() })
    defer { store.stop() }
    store.refreshAll()
    for _ in 0..<200 {
        if model.rateLimitStatus == .live && !store.isRefreshingClaude && !store.isRefreshingTeamo { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.rateLimitStatus == .live)
    store.setMenuRotationEnabled(true)
    // Synchronous rendering below cannot interleave other main-actor tests.
    let original = UserDefaults.standard.object(forKey: "monitorLanguage")
    defer { UserDefaults.standard.set(original, forKey: "monitorLanguage") }
    for language in AppLanguage.allCases {
        UserDefaults.standard.set(language.rawValue, forKey: "monitorLanguage")
        store.setLanguage(language)
        for mode in [MonitorColorMode.light, .dark] {
            store.appearance.mode = mode
            store.appearance.motion = .off
            let suffix = "\(language.rawValue)-\(mode.rawValue)"
            store.beginPopover()
            try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                        size: .init(width: 360, height: 540), url: directory.appendingPathComponent("collapsed-\(suffix).png"))
            store.toggleProviderDetails(.codex)
            try capture(MonitorView(model: model, store: store, onQuit: {}, onSettings: {}),
                        size: .init(width: 360, height: 540), url: directory.appendingPathComponent("expanded-\(suffix).png"))
            for section in MonitorSettingsSection.allCases {
                try capture(MonitorSettingsView(model: model, store: store, initialSection: section),
                            size: .init(width: 740, height: 600), url: directory.appendingPathComponent("settings-\(section.id)-\(suffix).png"))
            }
            try capture(MonitorSettingsView(model: model, store: store, expandedProviders: [.antigravity]),
                        size: .init(width: 740, height: 600), url: directory.appendingPathComponent("connection-\(suffix).png"))
            try capture(TeamoProviderSettings(store: store, expanded: true).padding(16)
                .frame(width: 510, height: 720, alignment: .top)
                .modifier(MonitorThemeScope(appearance: store.appearance)),
                        size: .init(width: 510, height: 720), url: directory.appendingPathComponent("teamo-\(suffix).png"))
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"] != nil))
@MainActor func rendersClaudeSettings() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PROVIDER_PREVIEW_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "claude-preview-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults, readClaude: { _ in
        .init(metrics: try ClaudeUsageReport.parse(Data(claudeUsageFixture.utf8)), planName: "Max · 示例")
    })
    defer { store.stop() }
    store.setClaudeEnabled(true)
    for _ in 0..<200 where store.isRefreshingClaude { try await Task.sleep(for: .milliseconds(5)) }
    #expect(store.claudeLastSuccessAt != nil)
    for (label, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
        try capture(ClaudeProviderSettings(store: store, expanded: true).padding(16)
            .frame(width: 520, height: 380, alignment: .top)
            .background { MonitorBackdrop() }.modifier(MonitorThemeScope(appearance: store.appearance))
            .environment(\.colorScheme, scheme),
                    size: NSSize(width: 520, height: 380), url: directory.appendingPathComponent("claude-settings-\(label).png"))
    }
}
