//
//  DynoPromptApp.swift
//  DynoPrompt
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import OSLog

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
    static let startPrompter = Notification.Name("startPrompter")
    static let openScriptLibrary = Notification.Name("openScriptLibrary")
    static let saveToLibrary = Notification.Name("saveToLibrary")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let lifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fka.dynoprompt",
        category: "AppLifecycle"
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Diagnostic mode: exercise the bundled speech stack and exit without
        // ever showing UI. The embedded XPC service can only be launched by
        // this bundle, so this is the only place the real path can be tested.
        if WhisperSelfTest.isRequested {
            WhisperSelfTest.run()
        }

        // Runs before any settings are read, so a returning user sees their
        // existing preferences rather than defaults.
        LegacyMigration.runIfNeeded()

        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            DynoPromptService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = DynoPromptService.shared
        NSUpdateDynamicServices()

        if DynoPromptService.shared.launchedExternally {
            DynoPromptService.shared.hideMainWindow()
        }

        #if !APP_STORE
        // Direct-download builds check GitHub for updates. App Store builds are
        // updated exclusively through the App Store.
        UpdateChecker.shared.checkForUpdates(silent: true)
        #endif

        // Warm the local speech model so the first session starts instantly.
        // Cheap when Whisper isn't the selected engine — it returns at once.
        DispatchQueue.global(qos: .utility).async {
            WhisperLocalProvider.prewarm()
        }

        // Start browser server if enabled
        DynoPromptService.shared.updateBrowserServer()

        // Start director server if enabled
        DynoPromptService.shared.updateDirectorServer()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if DynoPromptService.shared.hasUnsavedChanges {
            guard DynoPromptService.shared.confirmDiscardIfNeeded() else { return false }
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard
            DynoPromptService.shared.overlayController.isShowing,
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass,
            event.eventID == kAEQuitApplication,
            event.paramDescriptor(forKeyword: kAEQuitReason) == nil
        else {
            return .terminateNow
        }

        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let runningApplication = NSRunningApplication(processIdentifier: pid_t(senderPID))
        let senderName = runningApplication?.localizedName ?? "unknown"
        let senderBundleIdentifier = runningApplication?.bundleIdentifier ?? "unknown"

        lifecycleLogger.warning(
            "Blocked external quit while teleprompter is active; senderPID=\(senderPID, privacy: .public) sender=\(senderName, privacy: .public) bundleIdentifier=\(senderBundleIdentifier, privacy: .public)"
        )
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if DynoPromptService.shared.launchedExternally {
            DynoPromptService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "dynoprompt" {
                DynoPromptService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = DynoPromptService.shared.launchedExternally
                DynoPromptService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                DynoPromptService.shared.hideMainWindow()
                DynoPromptService.shared.handleURL(url)
            }
        }
    }
}

@main
struct DynoPromptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if url.pathExtension == "dynoprompt" {
                        DynoPromptService.shared.openFileAtURL(url)
                    } else {
                        DynoPromptService.shared.handleURL(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DynoPrompt") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                #if !APP_STORE
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
                #endif
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Script Library…") {
                    NotificationCenter.default.post(name: .openScriptLibrary, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Save to Library") {
                    NotificationCenter.default.post(name: .saveToLibrary, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Open File or Presentation…") {
                    DynoPromptService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    DynoPromptService.shared.saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    DynoPromptService.shared.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Start Prompter") {
                    NotificationCenter.default.post(name: .startPrompter, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("DynoPrompt Help") {
                    if let url = URL(string: "https://github.com/f/textream") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
