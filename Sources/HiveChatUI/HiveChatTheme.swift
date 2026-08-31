import SwiftUI
import HiveChat

/// Colours and copy for the drop-in chat UI.
///
/// Defaults come from the merchant's widget settings, so the chat in your app
/// matches the chat on their storefront without you configuring anything. Any
/// field you set explicitly wins — an app with its own design system usually
/// wants its own bubble colour and its own font.
public struct HiveChatTheme: Sendable {
    public var brandColor: Color
    public var brandGradientEnd: Color?
    /// Text drawn on top of ``brandColor``. Computed from the brand colour's
    /// luminance by default, because a merchant who picks a pale yellow gets
    /// white-on-yellow otherwise.
    public var onBrandColor: Color
    public var background: Color
    public var incomingBubble: Color
    public var incomingText: Color
    public var secondaryText: Color
    public var cornerRadius: CGFloat
    public var font: Font?

    public init(
        brandColor: Color = Color(red: 0.42, green: 0.24, blue: 0.88),
        brandGradientEnd: Color? = nil,
        onBrandColor: Color? = nil,
        background: Color = HivePalette.background,
        incomingBubble: Color = HivePalette.secondaryBackground,
        incomingText: Color = .primary,
        secondaryText: Color = .secondary,
        cornerRadius: CGFloat = 18,
        font: Font? = nil
    ) {
        self.brandColor = brandColor
        self.brandGradientEnd = brandGradientEnd
        self.onBrandColor = onBrandColor ?? brandColor.readableForeground
        self.background = background
        self.incomingBubble = incomingBubble
        self.incomingText = incomingText
        self.secondaryText = secondaryText
        self.cornerRadius = cornerRadius
        self.font = font
    }

    /// Builds a theme from the merchant's widget settings.
    public init(configuration: WidgetSettings) {
        let brand = Color(hex: configuration.brandColorHex) ?? Color(red: 0.42, green: 0.24, blue: 0.88)
        self.init(
            brandColor: brand,
            brandGradientEnd: configuration.gradientEndHex.flatMap(Color.init(hex:)),
            onBrandColor: brand.readableForeground
        )
    }

    var brandFill: LinearGradient {
        LinearGradient(
            colors: [brandColor, brandGradientEnd ?? brandColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    /// Parses `#RRGGBB` / `#RGB` / `#RRGGBBAA`, the shapes the dashboard's
    /// colour picker can produce. Returns nil rather than a wrong colour, so
    /// the caller falls back to its default.
    ///
    /// Deliberately internal. As `public` this added an initialiser to a
    /// SwiftUI type that host apps very commonly define themselves, and the
    /// two were indistinguishable at the call site: importing HiveChatUI broke
    /// every existing `Color(hex:)` in the app with "ambiguous use of
    /// init(hex:)". A chat SDK has no business claiming that name.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard let number = UInt64(value, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch value.count {
        case 3:
            r = Double((number >> 8) & 0xF) / 15
            g = Double((number >> 4) & 0xF) / 15
            b = Double(number & 0xF) / 15
            a = 1
        case 6:
            r = Double((number >> 16) & 0xFF) / 255
            g = Double((number >> 8) & 0xFF) / 255
            b = Double(number & 0xFF) / 255
            a = 1
        case 8:
            r = Double((number >> 24) & 0xFF) / 255
            g = Double((number >> 16) & 0xFF) / 255
            b = Double((number >> 8) & 0xFF) / 255
            a = Double(number & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Black or white, whichever stays legible on this colour.
    var readableForeground: Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        /* Rec. 709 luma. The 0.6 cut is deliberately above the usual 0.5:
           mid-brightness brand colours read better with white text than the
           strict threshold suggests. */
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luma > 0.6 ? .black : .white
        #else
        return .white
        #endif
    }
}

private struct HiveChatThemeKey: EnvironmentKey {
    static let defaultValue = HiveChatTheme()
}

extension EnvironmentValues {
    public var hiveChatTheme: HiveChatTheme {
        get { self[HiveChatThemeKey.self] }
        set { self[HiveChatThemeKey.self] = newValue }
    }
}

extension View {
    /// Overrides the chat's colours below this view.
    public func hiveChatTheme(_ theme: HiveChatTheme) -> some View {
        environment(\.hiveChatTheme, theme)
    }
}
