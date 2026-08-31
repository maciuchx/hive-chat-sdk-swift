import SwiftUI

/// System colours, resolved per platform.
///
/// `Color(.systemBackground)` and friends are UIKit-only spellings, so a
/// package that builds for macOS and visionOS as well has to go through one
/// place rather than scattering `#if canImport(UIKit)` through every view.
public enum HivePalette {
    public static var background: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    public static var secondaryBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    public static var tertiaryFill: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .quaternaryLabelColor)
        #endif
    }

    public static var separator: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }
}

import UniformTypeIdentifiers

extension URL {
    /// Best-effort MIME type from the file extension. The server falls back to
    /// treating anything unrecognised as a generic file, so a wrong guess
    /// costs an icon, not a delivery.
    var mimeType: String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
