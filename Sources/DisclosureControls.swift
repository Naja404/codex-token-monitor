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
                .animation(style.disclosureAnimation(expanded: expanded), value: expanded)
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

/// Reveal natural-sized content from its top edge; never squash text or recreate input state.
struct DisclosureLayout: Layout {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: .init(width: bounds.width, height: nil))
    }
}

struct DisclosureContent<Content: View>: View {
    let expanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.monitorStyle) private var style

    var body: some View {
        DisclosureLayout(progress: expanded ? 1 : 0) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .clipped()
        .opacity(expanded ? 1 : 0)
        .animation(style.disclosureAnimation(expanded: expanded), value: expanded)
        .allowsHitTesting(expanded).accessibilityHidden(!expanded)
        .disabled(!expanded)
    }
}

/// Keep inputs mounted when collapsed, so toggling a section never loses unsaved credentials.
struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.monitorStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title).font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? -180 : 0))
                        .animation(style.disclosureAnimation(expanded: expanded), value: expanded)
                }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.borderless)
                .accessibilityValue(L10n.text(expanded ? "已展开" : "已折叠"))
            DisclosureContent(expanded: expanded) {
                content().padding(.top, 12)
            }
        }
    }
}
