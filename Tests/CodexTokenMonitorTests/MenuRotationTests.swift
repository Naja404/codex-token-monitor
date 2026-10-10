import Foundation
import Testing
@testable import CodexTokenMonitor

@MainActor private func rotationStore() -> ProviderStore {
    let defaults = UserDefaults(suiteName: "rotation-tests-\(UUID().uuidString)")!
    defaults.set(true, forKey: "antigravityEnabled")
    return ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
}

@Test @MainActor func menuRotationCyclesWithoutChangingPinnedSource() {
    let store = rotationStore()
    store.setMenuRotationInterval(7, now: 0)
    store.setMenuRotationEnabled(true, now: 0)
    store.advanceMenuRotation(now: 6)
    #expect(store.displayedMenuSource == .codex)
    store.advanceMenuRotation(now: 7)
    #expect(store.displayedMenuSource == .antigravityGemini)
    #expect(store.menuLines.first.hasPrefix("G "))
    store.advanceMenuRotation(now: 14)
    #expect(store.displayedMenuSource == .antigravityThirdParty)
    store.advanceMenuRotation(now: 21)
    #expect(store.displayedMenuSource == .codex)
    #expect(store.menuSource == .codex)
    #expect(store.antigravityLastAttemptAt == nil)
    #expect(store.codex.lastRefreshAt == nil)
}

@Test @MainActor func menuRotationPausesForPopoverAndReturnsToFixedSource() {
    let store = rotationStore()
    store.setMenuRotationEnabled(true, now: 0)
    store.setMenuRotationInterval(5, now: 0)
    store.advanceMenuRotation(now: 5, paused: true)
    #expect(store.displayedMenuSource == .codex)
    store.advanceMenuRotation(now: 9)
    #expect(store.displayedMenuSource == .codex)
    store.advanceMenuRotation(now: 10)
    #expect(store.displayedMenuSource == .antigravityGemini)
    store.setMenuRotationEnabled(false, now: 11)
    #expect(store.displayedMenuSource == .codex)
    store.advanceMenuRotation(now: 100)
    #expect(store.displayedMenuSource == .codex)
}

@Test @MainActor func rotationPreferencesPersistAndClamp() {
    let name = "rotation-persistence-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(!store.menuRotationEnabled)
    #expect(store.menuRotationInterval == 10)
    store.setMenuRotationInterval(1)
    #expect(store.menuRotationInterval == 5)
    store.setMenuRotationInterval(100)
    #expect(store.menuRotationInterval == 60)
    store.setMenuRotationEnabled(true)
    let restored = ProviderStore(codex: UsageModel(defaults: defaults), defaults: defaults)
    #expect(restored.menuRotationEnabled)
    #expect(restored.menuRotationInterval == 60)
}

@Test @MainActor func rotationSkipsDisabledProvidersAndHandlesNoSources() {
    let store = rotationStore()
    store.setMenuRotationInterval(5, now: 0)
    store.setMenuRotationEnabled(true, now: 0)
    store.advanceMenuRotation(now: 5)
    store.setAntigravityEnabled(false)
    #expect(store.displayedMenuSource == .codex)
    store.advanceMenuRotation(now: 10_000_000)
    #expect(store.displayedMenuSource == .codex)
    store.setCodexEnabled(false)
    store.advanceMenuRotation(now: 10_000_010)
    #expect(store.menuLines.first == "未启用")
}
