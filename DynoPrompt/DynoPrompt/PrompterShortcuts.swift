//
//  PrompterShortcuts.swift
//  DynoPrompt
//
//  AppKit shim over `PrompterCommandMap`. The mapping table itself lives in
//  DynoPromptCore so it can be unit tested without a running app.
//

import AppKit

enum PrompterShortcutResolver {

    /// Maps an `NSEvent` key press to a session command, or nil to let the
    /// event through.
    static func command(
        forKeyCode keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> PrompterCommand? {
        PrompterCommandMap.command(
            keyCode: keyCode,
            characters: characters,
            modifiers: Self.modifiers(from: modifiers)
        )
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> PrompterModifiers {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
        var result: PrompterModifiers = []
        if relevant.contains(.shift)   { result.insert(.shift) }
        if relevant.contains(.option)  { result.insert(.option) }
        if relevant.contains(.command) { result.insert(.command) }
        if relevant.contains(.control) { result.insert(.control) }
        return result
    }
}
