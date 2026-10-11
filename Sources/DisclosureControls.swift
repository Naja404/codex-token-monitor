import SwiftUI

struct DisclosureButton: View {
    let title: String
    let expanded: Bool
    let action: () -> Void
    @Environment(\.monitorStyle) private var style
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(style.animation, value: expanded)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless).controlSize(.small)
        .help(L10n.text(expanded ? "收起明细" : "展开明细") + " · " + title)
        .accessibilityLabel(title)
        .accessibilityValue(L10n.text(expanded ? "已展开" : "已折叠", locale: locale))
        .accessibilityHint(L10n.text(expanded ? "收起明细" : "展开明细"))
    }
}

/// Keep inputs mounted when collapsed, so toggling a section never loses unsaved credentials.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title).font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.borderless)
                .accessibilityValue(L10n.text(expanded ? "已展开" : "已折叠"))
            content()
                .frame(height: expanded ? nil : 0, alignment: .top)
                .clipped().opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
                .disabled(!expanded)
        }
    }
}
