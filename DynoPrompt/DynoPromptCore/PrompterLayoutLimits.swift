//
//  PrompterLayoutLimits.swift
//  DynoPromptCore
//
//  Allowed ranges for the overlay's adjustable dimensions.
//
//  These are deliberately wide. The original design assumed a notch-sized
//  strip and capped width at 500 pt, which is wrong for anyone presenting on a
//  large display or feeding teleprompter glass. Every dimension here is a
//  continuous value rather than a handful of presets, because the right size
//  depends on how far the reader sits from the screen — which is a property of
//  their room, not something an app can pick for them.
//
//  Pure values with no UI dependency, so the ranges and the clamping can be
//  tested directly.
//

import CoreGraphics

public enum PrompterLayoutLimits {

    // MARK: - Overlay size

    public static let minWidth: CGFloat = 240
    public static let maxWidth: CGFloat = 1_600
    public static let defaultWidth: CGFloat = 340

    public static let minHeight: CGFloat = 80
    public static let maxHeight: CGFloat = 1_000
    public static let defaultHeight: CGFloat = 150

    // MARK: - Text

    public static let minFontSize: CGFloat = 10
    public static let maxFontSize: CGFloat = 96
    public static let defaultFontSize: CGFloat = 20

    /// Line spacing as a multiple of the font size.
    public static let minLineSpacing: CGFloat = 0.8
    public static let maxLineSpacing: CGFloat = 3.0
    public static let defaultLineSpacing: CGFloat = 1.4

    // MARK: - Opacity

    public static let minOpacity: CGFloat = 0.2
    public static let maxOpacity: CGFloat = 1.0

    // MARK: - Clamping

    public static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    public static func clampWidth(_ value: CGFloat) -> CGFloat {
        clamp(value, minWidth, maxWidth)
    }

    public static func clampHeight(_ value: CGFloat) -> CGFloat {
        clamp(value, minHeight, maxHeight)
    }

    public static func clampFontSize(_ value: CGFloat) -> CGFloat {
        clamp(value, minFontSize, maxFontSize)
    }

    public static func clampLineSpacing(_ value: CGFloat) -> CGFloat {
        clamp(value, minLineSpacing, maxLineSpacing)
    }

    /// Largest width that fits a display of the given size, with a margin.
    ///
    /// A value larger than the screen is allowed to be stored — the user may
    /// move to a bigger display — but the overlay fits itself to whatever
    /// screen it is actually on.
    public static func maximumWidth(forScreenWidth width: CGFloat) -> CGFloat {
        min(maxWidth, max(minWidth, width - 40))
    }

    /// Largest text height that fits a display of the given size, leaving room
    /// for the menu bar and the overlay's own controls.
    public static func maximumHeight(forScreenHeight height: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, height - 120))
    }
}
