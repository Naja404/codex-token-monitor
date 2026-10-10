import AppKit

/// Temporary native-window control experiment with offline fixtures only.
@MainActor
final class TouchBarNativeProbe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let cat = TouchBarRainbowCatView(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
    private var bar: NSTouchBar?
    private var catSelected = false
    private var timer: Timer?
    private var quotaController: MonitorHostingController?
    private var quotaSelected = false

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = TouchBarNativeProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }

    override init() {
        super.init()
        window.title = "Touch Bar 原生对照诊断"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let instruction = NSTextField(wrappingLabelWithString:
            "依次点击下方三个按钮，每次保持此窗口在前台至少 2 秒，观察键盘上的 Touch Bar。\n70% 是诊断示例，不是真实额度。")
        let textButton = NSButton(title: "1. 测试文字按钮", target: self, action: #selector(showText))
        let catButton = NSButton(title: "2. 测试动态小猫", target: self, action: #selector(showCat))
        let buttons = NSStackView(views: [textButton, catButton])
        buttons.spacing = 12
        let quotaButton = NSButton(title: "3. 测试完整额度栏（离线示例）", target: self, action: #selector(showQuota))
        let stack = NSStackView(views: [instruction, buttons, quotaButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showText()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record(.nativeSample) }
        }
    }

    @objc func showText() {
        quotaSelected = false
        quotaController?.setTouchBarVisible(false)
        catSelected = false
        cat.update(activity: .playful, visible: false, reducedMotion: false)
        let item = NSButtonTouchBarItem(identifier: .init("diagnostic.text"),
                                      title: "Touch Bar 测试 ✓", target: self, action: #selector(textPressed))
        install(item)
        record(.nativeText)
    }

    @objc func showCat() {
        quotaSelected = false
        quotaController?.setTouchBarVisible(false)
        catSelected = true
        let item = NSCustomTouchBarItem(identifier: .init("diagnostic.cat"))
        item.view = cat
        install(item)
        cat.update(activity: .playful, visible: true,
                   reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        record(.nativeCat)
    }

    @objc func showQuota() {
        catSelected = false
        cat.update(activity: .playful, visible: false, reducedMotion: false)
        if quotaController == nil {
            let defaults = UserDefaults(suiteName: "touchbar-probe-\(UUID().uuidString)")!
            let model = UsageModel(defaults: defaults, readUsage: { throw ProviderReadError.network })
            let fixture = QuotaWindow(name: "诊断示例", budget: 100, used: 30, resetsAt: .now)
            model.useManualValues(fiveHour: fixture, weekly: fixture)
            quotaController = MonitorHostingController(rootView: MonitorView(
                model: model, store: ProviderStore(codex: model, defaults: defaults), onQuit: {}, onSettings: {}
            ))
        }
        quotaSelected = true
        bar = quotaController?.touchBar
        window.touchBar = bar
        quotaController?.setTouchBarVisible(true)
        (bar?.item(forIdentifier: .init("codex.quota.refresh")) as? NSButtonTouchBarItem)?.isEnabled = false
        record(.nativeQuota)
    }

    private func install(_ item: NSTouchBarItem) {
        let replacement = NSTouchBar()
        replacement.defaultItemIdentifiers = [item.identifier]
        replacement.templateItems = [item]
        window.touchBar = replacement
        bar = replacement
    }

    @objc private func textPressed() { record(.nativeButtonPressed) }

    private func record(_ event: TouchBarDiagnostics.Event) {
        TouchBarDiagnostics.shared.record(event) {
            [.nativeProbe: true, .nativeCatSelected: catSelected, .nativeQuotaSelected: quotaSelected,
             .hasBundleIdentifier: Bundle.main.bundleIdentifier != nil,
             .appActive: NSApp.isActive,
             .appFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
             .hasKeyWindow: window.isKeyWindow, .barEligible: bar?.isVisible == true,
             .windowUsesBar: bar != nil && window.touchBar === bar,
             .catAnimating: quotaSelected ? quotaController?.touchBarDiagnosticState[.catAnimating] == true : cat.isAnimating]
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        quotaController?.setTouchBarVisible(false)
        cat.update(activity: .playful, visible: false, reducedMotion: false)
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { stop() }
}
