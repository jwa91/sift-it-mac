// The permissions opening a result at its place needs, asked for once and explained.
//
// `sift-it open` drives other apps with AppleScript, and macOS counts that as Sift It's doing:
// - a recording or video at its moment: QuickTime Player (Automation; macOS asks the first time by itself)
// - a PDF at its page: Preview and System Events (Automation), and Go to Page typed into Preview (Accessibility,
//   which macOS doesn't ask for by itself: it's granted in System Settings)

import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    /// Sift It may type into other apps: Preview's Go to Page.
    static var canType: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility, which shows its own prompt with the way to System Settings.
    static func askToType() {
        // kAXTrustedCheckOptionPrompt's value, spelled out: the global itself isn't safe to read from Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings("Privacy_Accessibility") }
    }

    static func openAutomationSettings() {
        openSettings("Privacy_Automation")
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let explainedKey = "explainedTyping"

    /// Before the first PDF opens at its page without Accessibility: says why it's needed, once. False when the
    /// person chose to set it up first, so the PDF isn't opened meanwhile.
    static func explainTypingOnce() -> Bool {
        guard !canType, !UserDefaults.standard.bool(forKey: explainedKey) else { return true }
        UserDefaults.standard.set(true, forKey: explainedKey)
        let alert = NSAlert()
        alert.messageText = "Open PDFs at the page?"
        alert.informativeText = """
            Preview can't be told a page to open at, so Sift It types Go to Page (⌥⌘G) for you. macOS calls that \
            Accessibility: allow Sift It once in System Settings, and PDFs open where they matched.

            Without it, the PDF opens at its first page.
            """
        alert.addButton(withTitle: "Allow in System Settings")
        alert.addButton(withTitle: "Open at the First Page")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        askToType()
        return false
    }
}
