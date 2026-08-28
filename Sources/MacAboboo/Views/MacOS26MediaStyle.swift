import SwiftUI
import AppKit

/// Shared visual language for the media workspace.
///
/// macOS 26 uses Liquid Glass only for the functional chrome (toolbar,
/// controls and transient navigation surfaces).  Media content remains on a
/// standard material so that the waveform, video and subtitles keep their
/// contrast.  The fallback deliberately uses the same semantic AppKit colors
/// on macOS 14 instead of hard-coded light/dark values.
enum MacAbobooMediaStyle {
    static let separator = Color(nsColor: .separatorColor)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let selectedBackground = Color(nsColor: .selectedContentBackgroundColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let accent = Color.accentColor
}

enum MacAbobooControlShape {
    case rounded
    case capsule
    case circle
}

/// Button style used by controls that sit on top of media or inside custom
/// panels.  On macOS 26 it provides the native interactive Liquid Glass
/// surface (including hover, pressed and keyboard-focus feedback).  On macOS
/// 14 it keeps an equivalent semantic material and pressed-state treatment.
struct MacAbobooChromeButtonStyle: ButtonStyle {
    let prominent: Bool
    let shape: MacAbobooControlShape

    init(prominent: Bool = false, shape: MacAbobooControlShape = .rounded) {
        self.prominent = prominent
        self.shape = shape
    }

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            switch shape {
            case .circle:
                configuration.label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .contentShape(Circle())
                    .glassEffect(
                        (prominent
                            ? Glass.regular.tint(MacAbobooMediaStyle.accent)
                            : Glass.regular).interactive(),
                        in: Circle()
                    )
                    .contentShape(Circle())
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1)
            case .capsule:
                configuration.label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .contentShape(Capsule())
                    .glassEffect(
                        (prominent
                            ? Glass.regular.tint(MacAbobooMediaStyle.accent)
                            : Glass.regular).interactive(),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1)
            case .rounded:
                configuration.label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .glassEffect(
                        (prominent
                            ? Glass.regular.tint(MacAbobooMediaStyle.accent)
                            : Glass.regular).interactive(),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1)
            }
        } else {
            MacAbobooFallbackControlBody(
                label: configuration.label,
                prominent: prominent,
                shape: shape,
                isPressed: configuration.isPressed
            )
        }
    }
}

private struct MacAbobooFallbackControlBody<Label: View>: View {
    let label: Label
    let prominent: Bool
    let shape: MacAbobooControlShape
    let isPressed: Bool
    @State private var isHovering = false

    var body: some View {
        Group {
            switch shape {
            case .circle:
                label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .background(Circle().fill(fillColor))
                    .overlay(Circle().stroke(MacAbobooMediaStyle.separator.opacity(0.55), lineWidth: 0.7))
                    .contentShape(Circle())
                    .opacity(isPressed ? 0.72 : 1)
                    .scaleEffect(isPressed ? 0.96 : 1)
            case .capsule:
                label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(fillColor))
                    .overlay(Capsule().stroke(MacAbobooMediaStyle.separator.opacity(0.55), lineWidth: 0.7))
                    .contentShape(Capsule())
                    .opacity(isPressed ? 0.72 : 1)
            case .rounded:
                label
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fillColor))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MacAbobooMediaStyle.separator.opacity(0.55), lineWidth: 0.7))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(isPressed ? 0.72 : 1)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fillColor: Color {
        if prominent { return MacAbobooMediaStyle.accent }
        return isHovering
            ? MacAbobooMediaStyle.panelBackground.opacity(0.92)
            : MacAbobooMediaStyle.panelBackground
    }
}

/// Selectable list-row treatment.  Rows are content, not navigation chrome,
/// so they use semantic fills instead of a separate glass capsule.  The
/// ButtonStyle still supplies a real pressed state for mouse and trackpad
/// input, which the old plain-button implementation did not provide.
struct MacAbobooSelectableRowButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let activeBg = colorScheme == .dark
            ? Color(red: 45.0 / 255.0, green: 45.0 / 255.0, blue: 48.0 / 255.0)
            : Color(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 242.0 / 255.0)

        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? activeBg
                            : (configuration.isPressed
                                ? MacAbobooMediaStyle.selectedBackground.opacity(0.18)
                                : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
    }
}

/// 与 `MacAbobooSelectableRowButtonStyle` 使用同一套视觉状态，但不要求把
/// 子控件嵌套进父 Button。断句行含有复选框和多个独立按钮时使用此版本。
private struct MacAbobooSelectableRowSurface: ViewModifier {
    let isActive: Bool
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let activeBackground = colorScheme == .dark
            ? Color(red: 45.0 / 255.0, green: 45.0 / 255.0, blue: 48.0 / 255.0)
            : Color(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 242.0 / 255.0)
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? activeBackground
                            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
    }
}

extension View {
    /// Apply a functional Liquid Glass button on macOS 26 and a semantic
    /// borderless control on macOS 14.  Keeping this as a view modifier makes
    /// it safe to use for toolbar/menu-adjacent controls without duplicating
    /// availability checks throughout the media views.
    @ViewBuilder
    func macabobooChromeButton(
        prominent: Bool = false,
        shape: MacAbobooControlShape = .rounded
    ) -> some View {
        self.buttonStyle(MacAbobooChromeButtonStyle(prominent: prominent, shape: shape))
    }

    func macabobooSelectableRowSurface(isActive: Bool, isHovered: Bool) -> some View {
        modifier(MacAbobooSelectableRowSurface(isActive: isActive, isHovered: isHovered))
    }

}

extension View {

    /// Standard material for media content panels.  It intentionally does not
    /// use Liquid Glass: Apple recommends standard materials for rich content
    /// layers such as video and waveforms.
    @ViewBuilder
    func macabobooContentSurface(cornerRadius: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(MacAbobooMediaStyle.separator.opacity(0.46), lineWidth: 0.7)
                )
        } else {
            self.background(MacAbobooMediaStyle.panelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(MacAbobooMediaStyle.separator.opacity(0.65), lineWidth: 0.7)
                )
        }
    }

    /// 侧栏/抽屉导航面板表面：采用高不透明度底色 (94%) 叠加超厚磨砂材质 (.ultraThickMaterial)，
    /// 确保阻隔底层复杂多媒体内容透光干扰的同时，保持纯正的 macOS 原生质感。
    @ViewBuilder
    func macabobooNavigationSurface(cornerRadius: CGFloat = 0) -> some View {
        self.background {
            ZStack {
                MacAbobooMediaStyle.windowBackground.opacity(0.94)
                Rectangle().fill(.ultraThickMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
