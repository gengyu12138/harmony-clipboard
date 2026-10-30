import AppKit
import SwiftUI

enum RelayTheme {
    static let accent = Color(red: 0.61, green: 0.86, blue: 0.77)
    static let ink = Color(white: 0.96)
    static let secondary = Color(white: 0.79)
    static let muted = Color(white: 0.70)
    static let line = Color.white.opacity(0.10)
    static let surface = Color.white.opacity(0.045)
    static let warning = Color(red: 1, green: 0.76, blue: 0.43)
}

private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassShell: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .foregroundStyle(RelayTheme.ink)
            .tint(RelayTheme.accent)
            .background {
                ZStack {
                    if !reduceTransparency { Glass() }
                    Color(red: 0.06, green: 0.08, blue: 0.09).opacity(reduceTransparency ? 1 : 0.64)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .preferredColorScheme(.dark)
    }
}

struct RelayButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    var destructive = false
    var quiet = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        RelayButtonBody(configuration: configuration, prominent: prominent, selected: selected,
                        destructive: destructive, quiet: quiet, isEnabled: isEnabled)
    }
}

private struct RelayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let selected: Bool
    let destructive: Bool
    let quiet: Bool
    let isEnabled: Bool
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 32)
            .foregroundStyle(prominent ? Color(red: 0.08, green: 0.17, blue: 0.14) : destructive ? Color(red: 1, green: 0.64, blue: 0.62) : selected ? RelayTheme.accent : RelayTheme.ink)
            .background(prominent ? RelayTheme.accent : selected ? RelayTheme.accent.opacity(0.13) : hovering ? .white.opacity(0.10) : quiet ? .clear : RelayTheme.surface,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? RelayTheme.accent.opacity(0.35) : quiet ? .clear : RelayTheme.line, lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
    }
}

struct RelayIconButton: View {
    let title: String
    let symbol: String
    var selected = false
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14) }
            .buttonStyle(RelayButtonStyle(selected: selected, destructive: destructive))
            .help(title).accessibilityLabel(title)
    }
}

struct RelayRow: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected ? RelayTheme.accent.opacity(0.13) : hovering ? Color.white.opacity(0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? RelayTheme.accent.opacity(0.32) : .clear, lineWidth: 1))
            .onHover { hovering = $0 }
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(RelayTheme.secondary).padding(.horizontal, 5).padding(.vertical, 3)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(RelayTheme.line, lineWidth: 0.5))
    }
}

struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(RelayTheme.secondary)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RelayTheme.line, lineWidth: 0.5))
        }
    }
}
