import Foundation
import AppKit
import SwiftUI
import Testing
@testable import CodexTokenMonitor

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
