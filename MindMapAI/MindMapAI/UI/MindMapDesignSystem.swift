import SwiftUI
import UIKit

/// Semantic colors for MindMap AI. Every color resolves through the current
/// appearance so feature views do not need their own light and dark palettes.
enum MindMapTheme {
    static let accent = Color.mindMapDynamic(
        light: UIColor(red: 0.05, green: 0.45, blue: 0.42, alpha: 1),
        dark: UIColor(red: 0.24, green: 0.82, blue: 0.74, alpha: 1)
    )

    static let primaryActionFill = Color.mindMapDynamic(
        light: UIColor(red: 0.04, green: 0.11, blue: 0.23, alpha: 1),
        dark: UIColor(red: 0.03, green: 0.28, blue: 0.27, alpha: 1)
    )

    static let accentSubtle = Color.mindMapDynamic(
        light: UIColor(red: 0.91, green: 0.97, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.07, green: 0.20, blue: 0.23, alpha: 1)
    )

    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .systemBackground)
    static let surfaceMuted = Color(uiColor: .secondarySystemGroupedBackground)
    static let textPrimary = Color(uiColor: .label)
    // Opaque semantic grays keep supporting copy above WCAG AA contrast on both
    // grouped and card surfaces. System secondary/tertiary labels use alpha and
    // can fall just below the accessibility audit threshold on grouped backgrounds.
    static let textSecondary = Color.mindMapDynamic(
        light: UIColor(red: 0.29, green: 0.30, blue: 0.33, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 1)
    )
    static let textTertiary = Color.mindMapDynamic(
        light: UIColor(red: 0.38, green: 0.39, blue: 0.42, alpha: 1),
        dark: UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    )
    static let border = Color(uiColor: .separator)
    static let disabledFill = Color.mindMapDynamic(
        light: UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.22, blue: 0.25, alpha: 1)
    )
    static let disabledText = Color.mindMapDynamic(
        light: UIColor(red: 0.31, green: 0.32, blue: 0.35, alpha: 1),
        dark: UIColor(red: 0.76, green: 0.78, blue: 0.82, alpha: 1)
    )

    static let success = Color.mindMapDynamic(
        light: UIColor(red: 0.10, green: 0.46, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.37, green: 0.82, blue: 0.55, alpha: 1)
    )

    static let warning = Color.mindMapDynamic(
        light: UIColor(red: 0.67, green: 0.37, blue: 0.03, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.69, blue: 0.29, alpha: 1)
    )

    static let error = Color.mindMapDynamic(
        light: UIColor(red: 0.70, green: 0.16, blue: 0.18, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.52, blue: 0.54, alpha: 1)
    )

    static let info = Color.mindMapDynamic(
        light: UIColor(red: 0.08, green: 0.39, blue: 0.66, alpha: 1),
        dark: UIColor(red: 0.42, green: 0.73, blue: 1.00, alpha: 1)
    )

    static let source = Color.mindMapDynamic(
        light: UIColor(red: 0.42, green: 0.25, blue: 0.62, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.59, blue: 1.00, alpha: 1)
    )

    static let coverage = Color.mindMapDynamic(
        light: UIColor(red: 0.04, green: 0.45, blue: 0.48, alpha: 1),
        dark: UIColor(red: 0.33, green: 0.80, blue: 0.81, alpha: 1)
    )
}

enum MindMapSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum MindMapCornerRadius {
    static let control: CGFloat = 12
    static let card: CGFloat = 18
    static let callout: CGFloat = 16
}

enum MindMapLayout {
    /// Keeps long-form content readable on iPad while still filling an iPhone.
    static let maxReadableWidth: CGFloat = 760
    static let maxFormWidth: CGFloat = 640
    static let minimumTapTarget: CGFloat = 44
    static let cardPadding: CGFloat = MindMapSpacing.large
}

/// Semantic Dynamic Type roles used throughout MindMap AI.
enum MindMapTextRole {
    case screenTitle
    case sectionTitle
    case cardTitle
    case body
    case supporting
    case caption
    case button
    case chip

    fileprivate var font: Font {
        switch self {
        case .screenTitle:
            return .largeTitle.weight(.bold)
        case .sectionTitle:
            return .title3.weight(.semibold)
        case .cardTitle:
            return .headline.weight(.semibold)
        case .body:
            return .body
        case .supporting:
            return .subheadline
        case .caption:
            return .caption
        case .button:
            return .headline
        case .chip:
            return .subheadline.weight(.medium)
        }
    }

    fileprivate var color: Color {
        switch self {
        case .supporting, .caption:
            return MindMapTheme.textSecondary
        default:
            return MindMapTheme.textPrimary
        }
    }
}

private struct MindMapTextStyleModifier: ViewModifier {
    let role: MindMapTextRole

    func body(content: Content) -> some View {
        content
            .font(role.font)
            .foregroundStyle(role.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MindMapCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(MindMapTheme.surface, in: shape)
            .overlay {
                shape.stroke(MindMapTheme.border.opacity(colorScheme == .dark ? 0.55 : 0.34), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(elevated ? (colorScheme == .dark ? 0.24 : 0.08) : 0),
                radius: elevated ? 12 : 0,
                x: 0,
                y: elevated ? 5 : 0
            )
    }
}

extension View {
    func mindMapTextStyle(_ role: MindMapTextRole) -> some View {
        modifier(MindMapTextStyleModifier(role: role))
    }

    func mindMapCardSurface(
        cornerRadius: CGFloat = MindMapCornerRadius.card,
        elevated: Bool = true
    ) -> some View {
        modifier(MindMapCardSurfaceModifier(cornerRadius: cornerRadius, elevated: elevated))
    }

    /// Centers readable content on regular-width devices without constraining phones.
    func mindMapReadableWidth(
        _ maxWidth: CGFloat = MindMapLayout.maxReadableWidth,
        alignment: Alignment = .center
    ) -> some View {
        frame(maxWidth: maxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct MindMapPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var expands: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MindMapTextRole.button.font)
            .foregroundStyle(isEnabled ? Color.white : MindMapTheme.disabledText)
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.vertical, MindMapSpacing.small)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                    .fill(isEnabled ? MindMapTheme.primaryActionFill : MindMapTheme.disabledFill)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MindMapSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var expands: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MindMapTextRole.button.font)
            .foregroundStyle(isEnabled ? MindMapTheme.accent : MindMapTheme.textTertiary)
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.vertical, MindMapSpacing.small)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? MindMapTheme.accentSubtle : MindMapTheme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                    .stroke(isEnabled ? MindMapTheme.accent.opacity(0.62) : MindMapTheme.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MindMapChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MindMapTextRole.chip.font)
            .foregroundStyle(isSelected ? Color.white : MindMapTheme.accent)
            .padding(.horizontal, MindMapSpacing.medium)
            .padding(.vertical, MindMapSpacing.small)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? MindMapTheme.primaryActionFill : MindMapTheme.accentSubtle)
            )
            .overlay {
                if !isSelected {
                    Capsule(style: .continuous)
                        .stroke(MindMapTheme.accent.opacity(0.28), lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.5)
    }
}

private extension Color {
    static func mindMapDynamic(light: UIColor, dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}
