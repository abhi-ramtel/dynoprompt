//
//  PrompterCommandMap.swift
//  DynoPromptCore
//
//  Key-to-command mapping for a running teleprompter session, kept free of
//  AppKit so the whole table can be unit tested. The app layer converts
//  `NSEvent` into these values.
//

import Foundation

public struct PrompterModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift   = PrompterModifiers(rawValue: 1 << 0)
    public static let option  = PrompterModifiers(rawValue: 1 << 1)
    public static let command = PrompterModifiers(rawValue: 1 << 2)
    public static let control = PrompterModifiers(rawValue: 1 << 3)
}

public enum PrompterCommand: String, CaseIterable, Identifiable {
    case stop
    case togglePause
    case toggleMicrophone
    case forwardWord
    case backWord
    case forwardSentence
    case backSentence
    case reset
    case increaseFont
    case decreaseFont
    case increaseOpacity
    case decreaseOpacity
    case increaseWidth
    case decreaseWidth
    case increaseHeight
    case decreaseHeight
    case nextPage

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stop:             return "Stop prompter"
        case .togglePause:      return "Pause / resume"
        case .toggleMicrophone: return "Mute / unmute microphone"
        case .forwardWord:      return "Forward one word"
        case .backWord:         return "Back one word"
        case .forwardSentence:  return "Forward one sentence"
        case .backSentence:     return "Back one sentence"
        case .reset:            return "Reset to start"
        case .increaseFont:     return "Increase font size"
        case .decreaseFont:     return "Decrease font size"
        case .increaseOpacity:  return "Increase opacity"
        case .decreaseOpacity:  return "Decrease opacity"
        case .increaseWidth:    return "Widen the overlay"
        case .decreaseWidth:    return "Narrow the overlay"
        case .increaseHeight:   return "Make the overlay taller"
        case .decreaseHeight:   return "Make the overlay shorter"
        case .nextPage:         return "Next page"
        }
    }

    /// Rendered shortcut, shared by Settings and the README so the two cannot
    /// drift apart.
    public var keyDescription: String {
        switch self {
        case .stop:             return "Esc"
        case .togglePause:      return "Space"
        case .toggleMicrophone: return "M"
        case .forwardWord:      return "→"
        case .backWord:         return "←"
        case .forwardSentence:  return "⌥→"
        case .backSentence:     return "⌥←"
        case .reset:            return "R"
        case .increaseFont:     return "+"
        case .decreaseFont:     return "−"
        case .increaseOpacity:  return "]"
        case .decreaseOpacity:  return "["
        case .increaseWidth:    return "⇧→"
        case .decreaseWidth:    return "⇧←"
        case .increaseHeight:   return "⇧↑"
        case .decreaseHeight:   return "⇧↓"
        case .nextPage:         return "Tab"
        }
    }
}

public enum PrompterKeyCode {
    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let tab: UInt16 = 48
}

public enum PrompterCommandMap {

    /// Resolves a key press to a session command, or nil to let the event
    /// through untouched.
    ///
    /// Events carrying Command or Control are always passed through so system
    /// and app shortcuts (⌘Q, ⌘Tab, ⌃F2) keep working while the overlay is on
    /// screen and swallowing keys.
    public static func command(
        keyCode: UInt16,
        characters: String?,
        modifiers: PrompterModifiers
    ) -> PrompterCommand? {
        if modifiers.contains(.command) || modifiers.contains(.control) { return nil }
        let option = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        switch keyCode {
        case PrompterKeyCode.escape:     return .stop
        case PrompterKeyCode.space:      return .togglePause
        // Shift + arrows resize the overlay live, so a presenter can dial in
        // the reading size on camera without opening Settings.
        case PrompterKeyCode.rightArrow: return shift ? .increaseWidth
                                              : (option ? .forwardSentence : .forwardWord)
        case PrompterKeyCode.leftArrow:  return shift ? .decreaseWidth
                                              : (option ? .backSentence : .backWord)
        case PrompterKeyCode.upArrow:    return shift ? .increaseHeight : .backWord
        case PrompterKeyCode.downArrow:  return shift ? .decreaseHeight : .forwardWord
        case PrompterKeyCode.tab:        return .nextPage
        default: break
        }

        switch characters?.lowercased() {
        case "m":      return .toggleMicrophone
        case "r":      return .reset
        case "+", "=": return .increaseFont
        case "-", "_": return .decreaseFont
        case "]":      return .increaseOpacity
        case "[":      return .decreaseOpacity
        default:       return nil
        }
    }
}

// MARK: - Update URL validation

public enum ReleaseURLValidator {
    /// Accepts only `https://github.com/...` release links.
    ///
    /// The update checker reads `html_url` out of a network response and hands
    /// it to the workspace opener. Without this check, a manipulated response
    /// could open a `file://` path or hand a custom scheme to another app.
    public static func safeReleaseURL(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        return url
    }
}
