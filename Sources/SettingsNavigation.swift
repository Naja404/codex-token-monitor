import AppKit
import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: MonitorSettingsSection
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MONITOR").font(.caption.weight(.semibold)).monitorSecondary().padding(10)
            ForEach(MonitorSettingsSection.allCases) { section in
                Label(L10n.text(section.rawValue, language: language), systemImage: section.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8).fill(.tint).opacity(selection == section ? 0.14 : 0)
                    }
                    .accessibilityHidden(true)
                    .overlay {
                        SettingsRowHitTarget(title: L10n.text(section.rawValue, language: language),
                                             identifier: section.symbol, selected: selection == section) {
                            selection = section
                        }
                        .contentShape(Rectangle())
                    }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Link("GitHub ↗", destination: AppIdentity.repositoryURL)
                Text(AppIdentity.current.versionLabel).textSelection(.enabled)
                Text(L10n.text("本地读取 · 按需开启", language: language))
            }.font(.caption).monitorSecondary().padding(10)
        }
        .frame(width: (language == .english ? 194 : 160) - 16, alignment: .leading)
        .padding(8).background(Color.primary.opacity(0.035))
    }
}

/// A real, full-bounds AppKit control avoids SwiftUI PlainButtonStyle shrinking
/// the mouse target to the visible glyphs inside a transparent label.
struct SettingsRowHitTarget: NSViewRepresentable {
    let title: String
    let identifier: String
    let selected: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> SettingsRowButton {
        let button = SettingsRowButton()
        button.isBordered = false
        button.title = ""
        button.setButtonType(.momentaryPushIn)
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = button
        button.action = #selector(SettingsRowButton.activateRow(_:))
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: SettingsRowButton, context: Context) {
        button.activate = action
        button.identifier = NSUserInterfaceItemIdentifier("settings-navigation-" + identifier)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selected ? 1 : 0)
    }
}

final class SettingsRowButton: NSButton {
    var activate: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func activateRow(_ sender: Any?) { activate?() }
}

/// Route sidebar points before SwiftUI's glyph-based platform hit testing.
/// Other content, including text fields and their responder chain, stays native.
final class SettingsHostingView: NSHostingView<MonitorSettingsView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        func row(in view: NSView) -> SettingsRowButton? {
            guard !view.isHidden, view.alphaValue > 0 else { return nil }
            if let button = view as? SettingsRowButton,
               button.bounds.contains(button.convert(local, from: self)),
               button.visibleRect.contains(button.convert(local, from: self)) { return button }
            for child in view.subviews {
                if let result = row(in: child) { return result }
            }
            return nil
        }
        for child in subviews {
            if let button = row(in: child) { return button }
        }
        return super.hitTest(point)
    }
}
