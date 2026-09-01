import SwiftUI
import AppKit

/// Shared visual language for the media workspace on macOS 26+.
///
/// macOS 26 uses Liquid Glass for functional chrome (toolbar, controls,
/// and transient navigation surfaces). Media content remains on a standard
/// material so that the waveform, video, and subtitles maintain maximum contrast.
enum StudyMateMediaStyle {
    static let separator = Color(nsColor: .separatorColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let accent = Color.accentColor
    static let informational = Color(nsColor: .systemBlue)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let destructive = Color(nsColor: .systemRed)
}

enum StudyMateControlShape {
    case rounded
    case capsule
    case circle
}

/// Button style used by controls that sit on top of media or inside custom panels.
/// Exclusively provides native macOS 26 Liquid Glass surfaces with interactive hover,
/// pressed, and keyboard-focus feedback.
struct StudyMateChromeButtonStyle: ButtonStyle {
    let prominent: Bool
    let shape: StudyMateControlShape

    init(prominent: Bool = false, shape: StudyMateControlShape = .rounded) {
        self.prominent = prominent
        self.shape = shape
    }

    func makeBody(configuration: Configuration) -> some View {
        switch shape {
        case .circle:
            configuration.label
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .contentShape(Circle())
                .glassEffect(
                    (prominent
                        ? Glass.regular.tint(StudyMateMediaStyle.accent)
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
                        ? Glass.regular.tint(StudyMateMediaStyle.accent)
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
                        ? Glass.regular.tint(StudyMateMediaStyle.accent)
                        : Glass.regular).interactive(),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(configuration.isPressed ? 0.78 : 1)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
        }
    }
}

private struct StudyMateSelectableRowSurface: ViewModifier {
    let isActive: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
    }
}

extension View {
    /// Apply native macOS 26 Liquid Glass button styling.
    func studymateChromeButton(
        prominent: Bool = false,
        shape: StudyMateControlShape = .rounded
    ) -> some View {
        self.buttonStyle(StudyMateChromeButtonStyle(prominent: prominent, shape: shape))
    }

    /// Functional chrome surface using macOS 26 Liquid Glass.
    func studymateChromeSurface(cornerRadius: CGFloat = 12) -> some View {
        self.glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Capsule variant for search fields and compact controls.
    func studymateChromeCapsule() -> some View {
        self.glassEffect(.regular, in: Capsule())
    }

    func studymateSelectableRowSurface(isActive: Bool, isHovered: Bool) -> some View {
        modifier(StudyMateSelectableRowSurface(isActive: isActive, isHovered: isHovered))
    }

    /// Standard material for media content panels.
    @ViewBuilder
    func studymateContentSurface(cornerRadius: CGFloat = 8) -> some View {
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(StudyMateMediaStyle.separator.opacity(0.46), lineWidth: 0.7)
            )
    }

    /// 侧栏/抽屉导航面板表面。
    func studymateNavigationSurface(cornerRadius: CGFloat = 0) -> some View {
        self.background(
            .ultraThickMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
