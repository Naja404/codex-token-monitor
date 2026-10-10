import AppKit
import Combine
import SwiftUI

enum MonitorTheme: String, CaseIterable, Identifiable {
    case native, aurora, graphite
    var id: String { rawValue }
    var title: String {
        switch self { case .native: "原生 · 清透"; case .aurora: "极光 · 微光"; case .graphite: "深空 · 石墨" }
    }
    var subtitle: String {
        switch self { case .native: "干净、轻盈、熟悉"; case .aurora: "薄雾柔光，安静悬浮"; case .graphite: "精细线条，冷静有序" }
    }
}

enum MonitorColorMode: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var override: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    func resolve(_ system: ColorScheme) -> ColorScheme { override ?? system }
}

enum MonitorMotion: String, CaseIterable {
    case gentle, off
    var title: String { self == .gentle ? "轻柔" : "关闭" }
    func allowsAnimation(reduceMotion: Bool, visible: Bool, active: Bool) -> Bool {
        self == .gentle && !reduceMotion && visible && active
    }
}

@MainActor final class MonitorAppearance: ObservableObject {
    @Published var theme: MonitorTheme { didSet { defaults.set(theme.rawValue, forKey: "monitorTheme") } }
    @Published var mode: MonitorColorMode { didSet { defaults.set(mode.rawValue, forKey: "monitorColorMode") } }
    @Published var motion: MonitorMotion { didSet { defaults.set(motion.rawValue, forKey: "monitorMotion") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = MonitorTheme(rawValue: defaults.string(forKey: "monitorTheme") ?? "") ?? .native
        mode = MonitorColorMode(rawValue: defaults.string(forKey: "monitorColorMode") ?? "") ?? .system
        motion = MonitorMotion(rawValue: defaults.string(forKey: "monitorMotion") ?? "") ?? .gentle
    }
}

struct ThemePalette {
    let background: NSColor
    let card: NSColor
    let primary: NSColor
    let secondary: NSColor
    let accent: NSColor
    let glow: NSColor

    init(theme: MonitorTheme, dark: Bool) {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                    green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        }
        primary = rgb(dark ? 0xEAF0FA : 0x1B2534)
        secondary = rgb(dark ? 0xB2BDD0 : 0x526078)
        switch theme {
        case .native:
            background = rgb(dark ? 0x222224 : 0xF2F2F5)
            card = rgb(dark ? 0x2C2C30 : 0xFFFFFF)
            accent = rgb(dark ? 0xA5C3FF : 0x315BB4)
            glow = accent
        case .aurora:
            background = rgb(dark ? 0x101729 : 0xEAF0FC)
            card = rgb(dark ? 0x192438 : 0xFAFCFF)
            accent = rgb(dark ? 0xB2BFFF : 0x564FA6)
            glow = rgb(dark ? 0x65CFC5 : 0x8AC6D3)
        case .graphite:
            background = rgb(dark ? 0x131A20 : 0xE8EDF1)
            card = rgb(dark ? 0x202B33 : 0xF8FAFC)
            accent = rgb(dark ? 0x80CCD8 : 0x24647C)
            glow = accent
        }
    }
}

struct MonitorStyle {
    var theme: MonitorTheme = .native
    var dark = false
    var solid = false
    var highContrast = false
    var motionEnabled = false
    var palette: ThemePalette { ThemePalette(theme: theme, dark: dark) }
    var animation: Animation? { motionEnabled ? .easeInOut(duration: 0.22) : nil }
}

private struct MonitorStyleKey: EnvironmentKey { static let defaultValue = MonitorStyle() }
extension EnvironmentValues {
    var monitorStyle: MonitorStyle {
        get { self[MonitorStyleKey.self] }
        set { self[MonitorStyleKey.self] = newValue }
    }
}

struct MonitorThemeScope: ViewModifier {
    @ObservedObject var appearance: MonitorAppearance
    var visible: Bool = true
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var active = NSApp?.isActive ?? false

    func body(content: Content) -> some View {
        let scheme = appearance.mode.resolve(systemScheme)
        let style = MonitorStyle(theme: appearance.theme, dark: scheme == .dark,
                                 solid: reduceTransparency || contrast == .increased,
                                 highContrast: contrast == .increased,
                                 motionEnabled: appearance.motion.allowsAnimation(
                                    reduceMotion: reduceMotion, visible: visible, active: active))
        content
            .environment(\.monitorStyle, style)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(appearance.mode.override)
            .foregroundStyle(Color(nsColor: style.palette.primary))
            .tint(Color(nsColor: style.palette.accent))
            .transaction { if !style.motionEnabled { $0.disablesAnimations = true } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
    }
}

struct MonitorBackdrop: View {
    @Environment(\.monitorStyle) private var style
    var body: some View {
        ZStack {
            Color(nsColor: style.palette.background)
            if !style.solid {
                if style.theme == .native {
                    Rectangle().fill(.regularMaterial).opacity(0.45)
                } else {
                    GeometryReader { proxy in
                        RadialGradient(colors: [Color(nsColor: style.palette.accent).opacity(style.dark ? 0.25 : 0.16), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: proxy.size.width * 1.05)
                        if style.theme == .aurora {
                            RadialGradient(colors: [Color(nsColor: style.palette.glow).opacity(style.dark ? 0.16 : 0.2), .clear],
                                           center: .bottomLeading, startRadius: 0, endRadius: proxy.size.width * 0.9)
                        }
                    }
                    // One short reveal on activation; no timer or continuously moving background.
                    .opacity(style.motionEnabled ? 1 : 0.8)
                    .animation(style.animation, value: style.motionEnabled)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct MonitorSurface: ViewModifier {
    @Environment(\.monitorStyle) private var style
    let successAt: Date?
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.theme == .graphite ? 10 : 12)
        content
            .background(Color(nsColor: style.palette.card).opacity(style.solid ? 1 : 0.96), in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [Color(nsColor: style.palette.accent).opacity(style.highContrast ? 0.8 : 0.32),
                             Color(nsColor: style.palette.primary).opacity(style.highContrast ? 0.5 : 0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: style.highContrast ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(style.theme == .native || style.solid ? 0 : style.dark ? 0.18 : 0.05), radius: 8, y: 3)
            .phaseAnimator([0.0, 1.0, 0.0], trigger: successAt) { card, phase in
                card.overlay {
                    shape.strokeBorder(Color(nsColor: style.palette.accent), lineWidth: 1.25)
                        .opacity(style.motionEnabled && successAt != nil ? phase * 0.6 : 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            } animation: { _ in style.motionEnabled ? .easeOut(duration: 0.18) : nil }
    }
}

extension View {
    func monitorSurface(successAt: Date? = nil) -> some View { modifier(MonitorSurface(successAt: successAt)) }
    func monitorSecondary() -> some View { modifier(MonitorSecondaryText()) }
}

private struct MonitorSecondaryText: ViewModifier {
    @Environment(\.monitorStyle) private var style
    func body(content: Content) -> some View { content.foregroundStyle(Color(nsColor: style.palette.secondary)) }
}

struct MonitorAppearanceSettings: View {
    @ObservedObject var appearance: MonitorAppearance
    @Environment(\.monitorStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTheme: MonitorTheme?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("为额度选择一种氛围").font(.headline)
            Text("只改变外观，不改变读取频率、额度颜色含义或供应商 Logo。")
                .font(.subheadline).monitorSecondary()
            HStack(spacing: 10) {
                ForEach(MonitorTheme.allCases) { theme in
                    Button { appearance.theme = theme } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemeSwatch(theme: theme, dark: style.dark).frame(height: 90).clipped()
                            Text(theme.title).font(.subheadline.weight(.semibold))
                            HStack {
                                Text(theme == appearance.theme ? "已选择" : "点击预览").font(.caption)
                                Spacer(minLength: 0)
                                Image(systemName: theme == appearance.theme ? "checkmark.circle.fill" : "circle")
                            }.foregroundStyle(Color(nsColor: theme == appearance.theme ? style.palette.accent : style.palette.secondary))
                        }.padding(10).frame(maxWidth: .infinity)
                            .background(Color(nsColor: style.palette.card), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                                theme == appearance.theme ? Color(nsColor: style.palette.accent) : Color.primary.opacity(0.12),
                                lineWidth: theme == appearance.theme ? 2 : 1))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                                Color(nsColor: style.palette.accent).opacity(focusedTheme == theme ? 1 : 0), lineWidth: 3))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(ThemeChoiceButtonStyle())
                        .focused($focusedTheme, equals: theme)
                        .accessibilityLabel(theme.title + "，" + theme.subtitle)
                        .accessibilityAddTraits(theme == appearance.theme ? .isSelected : [])
                }
            }
            Text(appearance.theme.subtitle).font(.subheadline).monitorSecondary()
            VStack(alignment: .leading, spacing: 16) {
                Picker("明暗", selection: $appearance.mode) {
                    ForEach(MonitorColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("界面动效", selection: $appearance.motion) {
                    ForEach(MonitorMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(reduceMotion ? "系统已开启“减少动态效果”，当前不播放界面动效。" : "轻柔：切换淡入淡出、数值过渡、刷新成功微光。无持续粒子动画，离开应用或关闭弹窗后停止。")
                    .font(.caption).monitorSecondary().fixedSize(horizontal: false, vertical: true)
            }.padding(16).monitorSurface()
            Label("即时生效 · 自动保存", systemImage: "checkmark.circle").font(.caption).monitorSecondary()
            Text("主题适用于弹窗和设置；菜单栏保持系统单色。减少透明度或增强对比度时使用实色背景。Touch Bar 小猫的动作规则保持不变。")
                .font(.caption).monitorSecondary().fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ThemeChoiceButtonStyle: ButtonStyle {
    @Environment(\.monitorStyle) private var style
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
            .animation(style.animation, value: configuration.isPressed)
    }
}

private struct ThemeSwatch: View {
    let theme: MonitorTheme
    let dark: Bool
    var body: some View {
        let palette = ThemePalette(theme: theme, dark: dark)
        ZStack {
            LinearGradient(colors: [Color(nsColor: palette.background),
                                    theme == .native ? Color(nsColor: palette.background) : Color(nsColor: palette.accent).opacity(0.35)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Circle().fill(Color(nsColor: palette.accent)).frame(width: 8, height: 8); Capsule().fill(Color(nsColor: palette.secondary).opacity(0.5)).frame(width: 34, height: 4) }
                Text("72%  /  38%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color(nsColor: palette.primary))
                Capsule().fill(Color(nsColor: palette.accent)).frame(height: 3)
            }.padding(10).background(Color(nsColor: palette.card), in: RoundedRectangle(cornerRadius: 7)).padding(10)
        }.clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
    }
}
