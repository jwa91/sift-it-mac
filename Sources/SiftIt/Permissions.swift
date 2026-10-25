// The permissions opening a result at its place needs, asked for once and explained, and their state as macOS has it:
// for Settings → Permissions and the welcome window, which show the same view.
//
// Reading folders needs none of this: macOS asks once for each protected folder (Documents, Desktop, Downloads), as
// Sift It, when the welcome window counts it right after it was chosen. The indexer and the engine run the sift-it in
// Contents/Helpers, and macOS counts what a program inside the app reads as the app's (tccd's bundle attribution), so
// they read the same folders without asking again.
//
// `sift-it open` drives other apps with AppleScript, and macOS counts that as Sift It's doing:
// - an audio file or video at its moment: QuickTime Player (Automation; macOS asks the first time by itself)
// - a PDF at its page: Preview and System Events (Automation), and Go to Page typed into Preview (Accessibility,
//   which macOS doesn't ask for by itself: it's granted in System Settings)
// Whether Sift It may drive an app can only be read while that app runs: AEDeterminePermissionToAutomateTarget says
// procNotFound before it looks. So the last answer read is kept for when it doesn't, and Allow… opens it hidden.

import AppKit
import ApplicationServices
import SwiftUI

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

/// An app `sift-it open` drives with Apple Events.
enum DrivenApp: String, CaseIterable {
    case preview = "com.apple.Preview"
    case systemEvents = "com.apple.systemevents"
    case quickTime = "com.apple.QuickTimePlayerX"

    var name: String {
        switch self {
        case .preview: "Preview"
        case .systemEvents: "System Events"
        case .quickTime: "QuickTime Player"
        }
    }

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

    @MainActor var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
}

/// Whether Sift It may do something: allowed, not allowed (changed in System Settings only), or not asked yet.
enum Answer {
    case allowed, denied, unasked
}

/// The permissions as macOS has them now, read again every second while a view shows them: System Settings doesn't
/// say when it changes them.
@MainActor @Observable
final class PermissionState {
    private(set) var canType = Permissions.canType
    private(set) var automation: [DrivenApp: Answer] = [:]
    /// The app macOS is asking about.
    private(set) var asking: DrivenApp?

    /// Reads the state every second, until the view showing it goes.
    func follow() async {
        while !Task.isCancelled {
            await look()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func look() async {
        canType = Permissions.canType
        for app in DrivenApp.allCases where app != asking {
            automation[app] = Self.answer(for: app, await Self.determine(app, asking: false))
        }
    }

    /// Asks whether Sift It may drive the app, which macOS asks the person once. It has to run for that: one that
    /// doesn't is opened hidden for the question, and quit again.
    func allow(_ app: DrivenApp) async {
        asking = app
        var opened: NSRunningApplication?
        if !app.isRunning, let url = app.url {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            opened = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        var status = await Self.determine(app, asking: true)
        // Just opened, it can take a moment to be found.
        for _ in 0..<20 where status == OSStatus(procNotFound) {
            try? await Task.sleep(for: .milliseconds(100))
            status = await Self.determine(app, asking: true)
        }
        opened?.terminate()
        automation[app] = Self.answer(for: app, status)
        asking = nil
    }

    /// Whether Sift It may send the app any Apple Event. Asking waits for the person's answer: never on the main thread.
    private static func determine(_ app: DrivenApp, asking: Bool) async -> OSStatus {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: app.rawValue)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, asking)
        }.value
    }

    /// What a status says, kept for when the app doesn't run and macOS can't say.
    private static func answer(for app: DrivenApp, _ status: OSStatus) -> Answer {
        let key = "automation." + app.rawValue
        switch Int(status) {
        case Int(noErr):
            UserDefaults.standard.set(true, forKey: key)
            return .allowed
        case errAEEventNotPermitted:
            UserDefaults.standard.set(false, forKey: key)
            return .denied
        case procNotFound:
            guard let allowed = UserDefaults.standard.object(forKey: key) as? Bool else { return .unasked }
            return allowed ? .allowed : .denied
        default:
            // errAEEventWouldRequireUserConsent: macOS hasn't asked yet.
            UserDefaults.standard.removeObject(forKey: key)
            return .unasked
        }
    }
}

/// Opening results where they matched: what it takes from macOS, each with its state now and the way to allow it.
struct PermissionsForm: View {
    /// With what happens without them, and how Allow… asks, under them.
    var explained = true
    @State private var state = PermissionState()

    var body: some View {
        Form {
            Section("PDFs at the page") {
                LabeledContent {
                    if state.canType {
                        allowed
                    } else {
                        Button("Allow…") { Permissions.askToType() }
                    }
                } label: {
                    Label {
                        Text("Accessibility")
                        Text("Types Go to Page (⌥⌘G) into Preview for you.")
                    } icon: {
                        Image(systemName: "accessibility").foregroundStyle(.tint)
                    }
                }
                row(.preview, "Opens the PDF.")
                row(.systemEvents, "Sends Go to Page to Preview.")
            }
            Section {
                row(.quickTime, "Opens the audio file or video, and plays it from the moment.")
            } header: {
                Text("Audio and video at the moment")
            } footer: {
                if explained {
                    Text(
                        """
                        Without them, results open at the start. macOS says whether Sift It may control an app while \
                        that app is open: Allow… opens it for a moment, hidden, and macOS asks.
                        """
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.follow() }
    }

    private func row(_ app: DrivenApp, _ use: String) -> some View {
        LabeledContent {
            if state.asking == app {
                ProgressView().controlSize(.small)
            } else {
                switch state.automation[app] {
                case .allowed: allowed
                case .denied:
                    HStack {
                        Text("Not allowed").foregroundStyle(.secondary)
                        Button("Open Settings…") { Permissions.openAutomationSettings() }
                    }
                case .unasked, nil:
                    Button("Allow…") { Task { await state.allow(app) } }
                        .disabled(state.asking != nil)
                }
            }
        } label: {
            Label {
                Text(app.name)
                Text(use)
            } icon: {
                if let url = app.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                }
            }
        }
    }

    private var allowed: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }
}
