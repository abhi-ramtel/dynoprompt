//
//  NotchSettings.swift
//  DynoPrompt
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

// MARK: - Font Size Preset

/// Quick picks for font size. The stored value is a continuous `fontSize`;
/// these are convenience buttons, not the only sizes available.
enum FontSizePreset: String, CaseIterable, Identifiable {
    case xs, sm, lg, xl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xs: return "XS"
        case .sm: return "SM"
        case .lg: return "LG"
        case .xl: return "XL"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .xs: return 14
        case .sm: return 16
        case .lg: return 20
        case .xl: return 24
        }
    }
}

// MARK: - Font Family Preset

enum FontFamilyPreset: String, CaseIterable, Identifiable {
    case sans, serif, mono, dyslexia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans:     return "Sans"
        case .serif:    return "Serif"
        case .mono:     return "Mono"
        case .dyslexia: return "Dyslexia"
        }
    }

    var sampleText: String {
        switch self {
        case .sans:     return "Aa"
        case .serif:    return "Aa"
        case .mono:     return "Aa"
        case .dyslexia: return "Aa"
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor
        switch self {
        case .sans:
            return base
        case .serif:
            if let designed = descriptor.withDesign(.serif) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return base
        case .mono:
            if let designed = descriptor.withDesign(.monospaced) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .dyslexia:
            if let dyslexicFont = NSFont(name: "OpenDyslexic3", size: size) {
                return dyslexicFont
            }
            // Fallback to rounded system font if OpenDyslexic not available
            if let designed = descriptor.withDesign(.rounded) {
                return NSFont(descriptor: designed, size: size) ?? base
            }
            return base
        }
    }
}

// MARK: - Font Color Preset

enum FontColorPreset: String, CaseIterable, Identifiable {
    case white, yellow, green, blue, pink, orange

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white:  return .white
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green:  return Color(red: 0.2, green: 0.84, blue: 0.29)
        case .blue:   return Color(red: 0.31, green: 0.55, blue: 1.0)
        case .pink:   return Color(red: 1.0, green: 0.38, blue: 0.57)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        }
    }

    var label: String {
        switch self {
        case .white:  return "White"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .pink:   return "Pink"
        case .orange: return "Orange"
        }
    }

    var cssColor: String {
        switch self {
        case .white:  return "#ffffff"
        case .yellow: return "rgb(255,214,10)"
        case .green:  return "rgb(51,214,74)"
        case .blue:   return "rgb(79,140,255)"
        case .pink:   return "rgb(255,97,145)"
        case .orange: return "rgb(255,158,10)"
        }
    }
}

// MARK: - Cue Brightness

enum CueBrightness: String, CaseIterable, Identifiable {
    case dim, low, medium, bright

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dim:    return "Dim"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .bright: return "Bright"
        }
    }

    /// Opacity for unread annotations
    var unreadOpacity: Double {
        switch self {
        case .dim:    return 0.2
        case .low:    return 0.35
        case .medium: return 0.5
        case .bright: return 0.8
        }
    }

    /// Opacity for already-read annotations
    var readOpacity: Double {
        switch self {
        case .dim:    return 0.5
        case .low:    return 0.6
        case .medium: return 0.7
        case .bright: return 1.0
        }
    }
}

// MARK: - Overlay Mode

enum OverlayMode: String, CaseIterable, Identifiable {
    case pinned, floating, fullscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pinned:     return "Pinned to Notch"
        case .floating:   return "Floating Window"
        case .fullscreen: return "Fullscreen"
        }
    }

    var description: String {
        switch self {
        case .pinned:     return "Anchored below the notch at the top of your screen."
        case .floating:   return "A draggable window you can place anywhere. Always on top."
        case .fullscreen: return "Fullscreen teleprompter on the selected display. Press Esc to stop."
        }
    }

    var icon: String {
        switch self {
        case .pinned:     return "rectangle.topthird.inset.filled"
        case .floating:   return "macwindow.on.rectangle"
        case .fullscreen: return "rectangle.fill"
        }
    }
}

// MARK: - Notch Display Mode

enum NotchDisplayMode: String, CaseIterable, Identifiable {
    case followMouse, fixedDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followMouse:  return "Follow Mouse"
        case .fixedDisplay: return "Fixed Display"
        }
    }

    var description: String {
        switch self {
        case .followMouse:  return "The notch moves to whichever display your mouse is on."
        case .fixedDisplay: return "The notch stays on the selected display."
        }
    }
}

// MARK: - External Display Mode

enum ExternalDisplayMode: String, CaseIterable, Identifiable {
    case off, teleprompter, mirror

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:          return "Off"
        case .teleprompter: return "Teleprompter"
        case .mirror:       return "Mirror"
        }
    }

    var description: String {
        switch self {
        case .off:          return "No external display output."
        case .teleprompter: return "Fullscreen teleprompter on the selected display."
        case .mirror:       return "Horizontally flipped for use with a prompter mirror rig."
        }
    }
}

// MARK: - Mirror Axis

enum MirrorAxis: String, CaseIterable, Identifiable {
    case horizontal, vertical, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical:   return "Vertical"
        case .both:       return "Both"
        }
    }

    var description: String {
        switch self {
        case .horizontal: return "Flipped left-to-right. Standard for prompter mirror rigs."
        case .vertical:   return "Flipped top-to-bottom."
        case .both:       return "Flipped on both axes (rotated 180°)."
        }
    }

    var scaleX: CGFloat {
        switch self {
        case .horizontal, .both: return -1
        case .vertical: return 1
        }
    }

    var scaleY: CGFloat {
        switch self {
        case .vertical, .both: return -1
        case .horizontal: return 1
        }
    }
}

// MARK: - Listening Mode

enum ListeningMode: String, CaseIterable, Identifiable {
    case wordTracking, classic, silencePaused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:        return "Classic"
        case .silencePaused:  return "Voice-Activated"
        case .wordTracking:   return "Word Tracking"
        }
    }

    var description: String {
        switch self {
        case .classic:        return "Auto-scrolls at a constant speed. No microphone needed."
        case .silencePaused:  return "Scrolls while you speak, pauses when you're silent."
        case .wordTracking:   return "Tracks each word you say and highlights it in real time."
        }
    }

    var icon: String {
        switch self {
        case .classic:        return "arrow.down.circle"
        case .silencePaused:  return "waveform.circle"
        case .wordTracking:   return "text.word.spacing"
        }
    }
}

// MARK: - Reading Position

enum ReadingPosition: String, CaseIterable, Identifiable {
    case centered, nearTop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .centered: return "Centered"
        case .nearTop:  return "Near Top"
        }
    }
}

// MARK: - Speech Recognition Engine

/// Which local speech engine drives Word Tracking.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// Apple's recognizer, pinned to on-device mode.
    case appleOnDevice
    /// A local whisper.cpp server, optionally reusing an OpenWhispr install.
    case whisperLocal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleOnDevice: return "Apple (On-Device)"
        case .whisperLocal:  return "Whisper (Local)"
        }
    }

    var detail: String {
        switch self {
        case .appleOnDevice:
            return "Apple's built-in recognizer, forced to on-device mode. No audio leaves this Mac."
        case .whisperLocal:
            return "Built-in whisper.cpp, running in a sandboxed helper with no network access. "
                + "Better with accents and jargon; can also use an OpenWhispr model you already have."
        }
    }
}

// MARK: - Settings

@Observable
class NotchSettings {
    static let shared = NotchSettings()

    // Clamped properties use a private backing store and a computed accessor
    // rather than `didSet`.
    //
    // Assigning to a property inside its own `didSet` normally does not
    // re-enter — but `@Observable` rewrites stored properties into computed
    // accessors, which removes that guarantee. The self-assignment then goes
    // back through the setter and recurses until the stack is exhausted, which
    // crashed the app the moment Settings bound a slider to one of these.
    private var storedNotchWidth: CGFloat
    var notchWidth: CGFloat {
        get { storedNotchWidth }
        set {
            let clamped = PrompterLayoutLimits.clampWidth(newValue)
            guard clamped != storedNotchWidth else { return }
            storedNotchWidth = clamped
            UserDefaults.standard.set(Double(clamped), forKey: "notchWidth")
        }
    }

    private var storedTextAreaHeight: CGFloat
    var textAreaHeight: CGFloat {
        get { storedTextAreaHeight }
        set {
            let clamped = PrompterLayoutLimits.clampHeight(newValue)
            guard clamped != storedTextAreaHeight else { return }
            storedTextAreaHeight = clamped
            UserDefaults.standard.set(Double(clamped), forKey: "textAreaHeight")
        }
    }

    var speechLocale: String {
        didSet { UserDefaults.standard.set(speechLocale, forKey: "speechLocale") }
    }

    var speechEngine: SpeechEngine {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: "speechEngine") }
    }

    /// When true (the default) DynoPrompt refuses to run Word Tracking unless
    /// recognition is happening entirely on this Mac.
    ///
    /// Apple's `SFSpeechRecognizer` will silently stream microphone audio to
    /// Apple's servers when a locale has no on-device model installed. For a
    /// teleprompter — where the microphone is live for the whole session and
    /// the script may be unreleased material — that is a privacy decision the
    /// user should make explicitly, not a silent fallback.
    var requireOnDeviceSpeech: Bool {
        didSet { UserDefaults.standard.set(requireOnDeviceSpeech, forKey: "requireOnDeviceSpeech") }
    }

    /// Identifier of the speech model the user chose, e.g. "ggml-base.en".
    /// Empty means "whatever is bundled".
    var activeSpeechModelID: String {
        didSet { UserDefaults.standard.set(activeSpeechModelID, forKey: "activeSpeechModelID") }
    }

    /// Absolute path of the GGML model used by the Whisper engine.
    var whisperModelPath: String {
        didSet { UserDefaults.standard.set(whisperModelPath, forKey: "whisperModelPath") }
    }

    /// Optional explicit path to a whisper.cpp server binary.
    var whisperBinaryPath: String {
        didSet { UserDefaults.standard.set(whisperBinaryPath, forKey: "whisperBinaryPath") }
    }

    /// Overlay text size in points. Continuous rather than one of four fixed
    /// presets: a teleprompter is read at whatever distance the camera
    /// dictates, so the right size is per-setup, not per-taste.
    private var storedFontSize: CGFloat
    var fontSize: CGFloat {
        get { storedFontSize }
        set {
            let clamped = PrompterLayoutLimits.clampFontSize(newValue)
            guard clamped != storedFontSize else { return }
            storedFontSize = clamped
            UserDefaults.standard.set(Double(clamped), forKey: "fontSize")
        }
    }

    /// Line spacing as a multiple of the font size.
    private var storedLineSpacingMultiplier: CGFloat
    var lineSpacingMultiplier: CGFloat {
        get { storedLineSpacingMultiplier }
        set {
            let clamped = PrompterLayoutLimits.clampLineSpacing(newValue)
            guard clamped != storedLineSpacingMultiplier else { return }
            storedLineSpacingMultiplier = clamped
            UserDefaults.standard.set(Double(clamped), forKey: "lineSpacingMultiplier")
        }
    }

    /// The nearest quick pick, used to highlight the preset buttons. Setting
    /// it just writes the preset's point size into `fontSize`.
    var fontSizePreset: FontSizePreset {
        get {
            FontSizePreset.allCases.min(
                by: { abs($0.pointSize - fontSize) < abs($1.pointSize - fontSize) }
            ) ?? .lg
        }
        set { fontSize = newValue.pointSize }
    }

    var fontFamilyPreset: FontFamilyPreset {
        didSet { UserDefaults.standard.set(fontFamilyPreset.rawValue, forKey: "fontFamilyPreset") }
    }

    var fontColorPreset: FontColorPreset {
        didSet { UserDefaults.standard.set(fontColorPreset.rawValue, forKey: "fontColorPreset") }
    }

    var cueColorPreset: FontColorPreset {
        didSet { UserDefaults.standard.set(cueColorPreset.rawValue, forKey: "cueColorPreset") }
    }

    var cueBrightness: CueBrightness {
        didSet { UserDefaults.standard.set(cueBrightness.rawValue, forKey: "cueBrightness") }
    }

    var overlayMode: OverlayMode {
        didSet { UserDefaults.standard.set(overlayMode.rawValue, forKey: "overlayMode") }
    }

    var notchDisplayMode: NotchDisplayMode {
        didSet { UserDefaults.standard.set(notchDisplayMode.rawValue, forKey: "notchDisplayMode") }
    }

    var pinnedScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(pinnedScreenID), forKey: "pinnedScreenID") }
    }

    var floatingGlassEffect: Bool {
        didSet { UserDefaults.standard.set(floatingGlassEffect, forKey: "floatingGlassEffect") }
    }

    var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: "glassOpacity") }
    }

    var overlayTransparency: Bool {
        didSet { UserDefaults.standard.set(overlayTransparency, forKey: "overlayTransparency") }
    }

    var overlayTransparencyOpacity: Double {
        didSet { UserDefaults.standard.set(overlayTransparencyOpacity, forKey: "overlayTransparencyOpacity") }
    }

    var followCursorWhenUndocked: Bool {
        didSet { UserDefaults.standard.set(followCursorWhenUndocked, forKey: "followCursorWhenUndocked") }
    }

    var externalDisplayMode: ExternalDisplayMode {
        didSet { UserDefaults.standard.set(externalDisplayMode.rawValue, forKey: "externalDisplayMode") }
    }

    var externalScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(externalScreenID), forKey: "externalScreenID") }
    }

    var mirrorAxis: MirrorAxis {
        didSet { UserDefaults.standard.set(mirrorAxis.rawValue, forKey: "mirrorAxis") }
    }

    var listeningMode: ListeningMode {
        didSet { UserDefaults.standard.set(listeningMode.rawValue, forKey: "listeningMode") }
    }

    /// Words per second for classic and silence-paused modes
    var scrollSpeed: Double {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed") }
    }

    var hideFromScreenShare: Bool {
        didSet { UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare") }
    }

    var showElapsedTime: Bool {
        didSet { UserDefaults.standard.set(showElapsedTime, forKey: "showElapsedTime") }
    }

    var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake")
            DynoPromptService.shared.updateKeepAwakeActivity(enabled: keepScreenAwake)
        }
    }

    var readingPosition: ReadingPosition {
        didSet { UserDefaults.standard.set(readingPosition.rawValue, forKey: "readingPosition") }
    }

    var showParagraphDividers: Bool {
        didSet { UserDefaults.standard.set(showParagraphDividers, forKey: "showParagraphDividers") }
    }

    var showLastSpokenWords: Bool {
        didSet { UserDefaults.standard.set(showLastSpokenWords, forKey: "showLastSpokenWords") }
    }

    var selectedMicUID: String {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "selectedMicUID") }
    }

    var autoNextPage: Bool {
        didSet { UserDefaults.standard.set(autoNextPage, forKey: "autoNextPage") }
    }

    var autoNextPageDelay: Int {
        didSet { UserDefaults.standard.set(autoNextPageDelay, forKey: "autoNextPageDelay") }
    }

    var fullscreenScreenID: UInt32 {
        didSet { UserDefaults.standard.set(Int(fullscreenScreenID), forKey: "fullscreenScreenID") }
    }

    var browserServerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(browserServerEnabled, forKey: "browserServerEnabled")
            DynoPromptService.shared.updateBrowserServer()
        }
    }

    var browserServerPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(browserServerPort), forKey: "browserServerPort") }
    }

    var directorModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(directorModeEnabled, forKey: "directorModeEnabled")
            DynoPromptService.shared.updateDirectorServer()
        }
    }

    var directorServerPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(directorServerPort), forKey: "directorServerPort") }
    }

    var font: NSFont {
        fontFamilyPreset.font(size: fontSize)
    }

    static let defaultWidth = PrompterLayoutLimits.defaultWidth
    static let defaultHeight = PrompterLayoutLimits.defaultHeight
    static let defaultLocale: String = SpeechLocaleSupport.closestSupportedLocale(to: Locale.current.identifier)?.identifier
        ?? Locale.current.identifier

    // Ranges are deliberately generous. The old 310–500 pt width suited a
    // notch-sized strip and nothing else; a presenter on a large display, or
    // one mirroring to teleprompter glass, needs far more. The overlay clamps
    // to the screen it is on, so an oversized value degrades to "as wide as
    // this display" rather than drawing off-screen.
    static let minWidth = PrompterLayoutLimits.minWidth
    static let maxWidth = PrompterLayoutLimits.maxWidth
    static let minHeight = PrompterLayoutLimits.minHeight
    static let maxHeight = PrompterLayoutLimits.maxHeight

    // The ranges live in DynoPromptCore so they can be unit tested without a
    // running app; these are the names the views already use.
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        PrompterLayoutLimits.clamp(value, lower, upper)
    }

    static let minFontSize = PrompterLayoutLimits.minFontSize
    static let maxFontSize = PrompterLayoutLimits.maxFontSize
    static let defaultFontSize = PrompterLayoutLimits.defaultFontSize

    static let minLineSpacing = PrompterLayoutLimits.minLineSpacing
    static let maxLineSpacing = PrompterLayoutLimits.maxLineSpacing
    static let defaultLineSpacing = PrompterLayoutLimits.defaultLineSpacing

    /// Largest width that fits the given screen, with a margin.
    static func maximumWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return maxWidth }
        return PrompterLayoutLimits.maximumWidth(forScreenWidth: screen.visibleFrame.width)
    }

    /// Largest text height that fits the given screen, with a margin.
    static func maximumHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return maxHeight }
        return PrompterLayoutLimits.maximumHeight(forScreenHeight: screen.visibleFrame.height)
    }

    init() {
        // Clamp on the way in as well as on assignment. `didSet` does not run
        // during init, so a value that is out of range on disk — an older
        // build's wider limits, a hand-edited plist, a corrupt preference —
        // would otherwise survive and draw the overlay off-screen.
        let savedWidth = UserDefaults.standard.double(forKey: "notchWidth")
        let savedHeight = UserDefaults.standard.double(forKey: "textAreaHeight")
        self.storedNotchWidth = PrompterLayoutLimits.clampWidth(
            savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultWidth
        )
        self.storedTextAreaHeight = PrompterLayoutLimits.clampHeight(
            savedHeight > 0 ? CGFloat(savedHeight) : Self.defaultHeight
        )
        let preferredSpeechLocale = UserDefaults.standard.string(forKey: "speechLocale") ?? Self.defaultLocale
        self.speechLocale = SpeechLocaleSupport.closestSupportedLocale(to: preferredSpeechLocale)?.identifier
            ?? Self.defaultLocale
        self.speechEngine = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: "speechEngine") ?? "") ?? .appleOnDevice
        // Defaults to true: privacy is the default, and opting out is a
        // deliberate act.
        self.requireOnDeviceSpeech = UserDefaults.standard.object(forKey: "requireOnDeviceSpeech") as? Bool ?? true
        self.activeSpeechModelID = UserDefaults.standard.string(forKey: "activeSpeechModelID")
            ?? SpeechModelCatalog.bundledModelID
        self.whisperModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
        self.whisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        // Migrate from the old four-preset setting the first time through.
        let savedFontSize = UserDefaults.standard.double(forKey: "fontSize")
        if savedFontSize > 0 {
            self.storedFontSize = PrompterLayoutLimits.clampFontSize(CGFloat(savedFontSize))
        } else {
            let legacy = FontSizePreset(
                rawValue: UserDefaults.standard.string(forKey: "fontSizePreset") ?? ""
            )
            self.storedFontSize = PrompterLayoutLimits.clampFontSize(
                legacy?.pointSize ?? Self.defaultFontSize
            )
        }
        let savedLineSpacing = UserDefaults.standard.double(forKey: "lineSpacingMultiplier")
        self.storedLineSpacingMultiplier = savedLineSpacing > 0
            ? PrompterLayoutLimits.clampLineSpacing(CGFloat(savedLineSpacing))
            : Self.defaultLineSpacing
        self.fontFamilyPreset = FontFamilyPreset(rawValue: UserDefaults.standard.string(forKey: "fontFamilyPreset") ?? "") ?? .sans
        self.fontColorPreset = FontColorPreset(rawValue: UserDefaults.standard.string(forKey: "fontColorPreset") ?? "") ?? .white
        self.cueColorPreset = FontColorPreset(rawValue: UserDefaults.standard.string(forKey: "cueColorPreset") ?? "") ?? .white
        self.cueBrightness = CueBrightness(rawValue: UserDefaults.standard.string(forKey: "cueBrightness") ?? "") ?? .dim
        self.overlayMode = OverlayMode(rawValue: UserDefaults.standard.string(forKey: "overlayMode") ?? "") ?? .pinned
        self.notchDisplayMode = NotchDisplayMode(rawValue: UserDefaults.standard.string(forKey: "notchDisplayMode") ?? "") ?? .followMouse
        let savedPinnedScreenID = UserDefaults.standard.integer(forKey: "pinnedScreenID")
        self.pinnedScreenID = UInt32(savedPinnedScreenID)
        self.floatingGlassEffect = UserDefaults.standard.object(forKey: "floatingGlassEffect") as? Bool ?? false
        let savedOpacity = UserDefaults.standard.double(forKey: "glassOpacity")
        self.glassOpacity = savedOpacity > 0 ? savedOpacity : 0.15
        self.overlayTransparency = UserDefaults.standard.object(forKey: "overlayTransparency") as? Bool ?? false
        let savedTransparencyOpacity = UserDefaults.standard.double(forKey: "overlayTransparencyOpacity")
        self.overlayTransparencyOpacity = savedTransparencyOpacity > 0 ? savedTransparencyOpacity : 0.85
        self.followCursorWhenUndocked = UserDefaults.standard.object(forKey: "followCursorWhenUndocked") as? Bool ?? false
        self.externalDisplayMode = ExternalDisplayMode(rawValue: UserDefaults.standard.string(forKey: "externalDisplayMode") ?? "") ?? .off
        let savedScreenID = UserDefaults.standard.integer(forKey: "externalScreenID")
        self.externalScreenID = UInt32(savedScreenID)
        self.mirrorAxis = MirrorAxis(rawValue: UserDefaults.standard.string(forKey: "mirrorAxis") ?? "") ?? .horizontal
        self.listeningMode = ListeningMode(rawValue: UserDefaults.standard.string(forKey: "listeningMode") ?? "") ?? .wordTracking
        let savedSpeed = UserDefaults.standard.double(forKey: "scrollSpeed")
        self.scrollSpeed = savedSpeed > 0 ? savedSpeed : 3
        self.hideFromScreenShare = UserDefaults.standard.object(forKey: "hideFromScreenShare") as? Bool ?? true
        self.showElapsedTime = UserDefaults.standard.object(forKey: "showElapsedTime") as? Bool ?? true
        self.keepScreenAwake = UserDefaults.standard.object(forKey: "keepScreenAwake") as? Bool ?? false
        self.readingPosition = ReadingPosition(rawValue: UserDefaults.standard.string(forKey: "readingPosition") ?? "") ?? .centered
        self.showParagraphDividers = UserDefaults.standard.object(forKey: "showParagraphDividers") as? Bool ?? false
        self.showLastSpokenWords = UserDefaults.standard.object(forKey: "showLastSpokenWords") as? Bool ?? true
        self.selectedMicUID = UserDefaults.standard.string(forKey: "selectedMicUID") ?? ""
        self.autoNextPage = UserDefaults.standard.object(forKey: "autoNextPage") as? Bool ?? false
        let savedDelay = UserDefaults.standard.integer(forKey: "autoNextPageDelay")
        self.autoNextPageDelay = [0, 1, 3, 5].contains(savedDelay)
            && UserDefaults.standard.object(forKey: "autoNextPageDelay") != nil
            ? savedDelay
            : 3
        let savedFullscreenScreenID = UserDefaults.standard.integer(forKey: "fullscreenScreenID")
        self.fullscreenScreenID = UInt32(savedFullscreenScreenID)
        self.browserServerEnabled = UserDefaults.standard.object(forKey: "browserServerEnabled") as? Bool ?? false
        let savedPort = UserDefaults.standard.integer(forKey: "browserServerPort")
        self.browserServerPort = (1024..<Int(UInt16.max)).contains(savedPort) ? UInt16(savedPort) : 7373
        self.directorModeEnabled = UserDefaults.standard.object(forKey: "directorModeEnabled") as? Bool ?? false
        let savedDirectorPort = UserDefaults.standard.integer(forKey: "directorServerPort")
        self.directorServerPort = (1024..<Int(UInt16.max)).contains(savedDirectorPort) ? UInt16(savedDirectorPort) : 7575
    }
}
