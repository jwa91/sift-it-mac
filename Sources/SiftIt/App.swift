// Sift It: a search bar over everything on this Mac, for sift-it's engine. It lives in the menu bar; a shortcut opens
// the search from any app.

import AppKit

@main
@MainActor
enum App {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// The app shows no menu bar of its own, but the search field's ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z go through these.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private var search: SearchController!
    private var hotkey: Hotkey!
    private var statusItem: StatusItem!
    private var settings: SettingsWindow!
    private var setup: Setup!
    private var welcome: WelcomeWindow!

    /// Everything is made before launching finishes: a `sift-it://` link that launched the app comes in before
    /// `applicationDidFinishLaunching`. The panel is made now too, so the first shortcut shows it at once.
    func applicationWillFinishLaunching(_ notification: Notification) {
        search = SearchController(engine: engine)
        hotkey = Hotkey { [weak self] in self?.search.toggle() }
        hotkey.register(.saved)
        setup = Setup(engine: engine)
        welcome = WelcomeWindow(engine: engine, setup: setup, hotkey: hotkey)
        welcome.onFinish = { [weak self] in self?.search.show() }
        settings = SettingsWindow(engine: engine, setup: setup, hotkey: hotkey)
        settings.openWelcome = { [weak self] in self?.welcome.show() }
        statusItem = StatusItem(engine: engine)
        statusItem.openSearch = { [weak self] in self?.search.show() }
        statusItem.openSettings = { [weak self] in self?.settings.show() }
        statusItem.startIndexing = { [weak self] in Task { try? await self?.setup.indexInBackground(true) } }
        search.openSettings = { [weak self] in self?.settings.show() }
        engine.watch()
    }

    /// The first time, the welcome window sets Sift It up. After that, launching puts back what an upgrade took away.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            if await setup.needsWelcome() {
                welcome.show()
            } else {
                await setup.restoreBackground()
            }
        }
    }

    /// `sift-it://search?q=…` opens the search with that query, `sift-it://settings` the settings, and
    /// `sift-it://welcome` the welcome window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "sift-it" {
            switch url.host() {
            case "search":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "q" }?.value
                search.show(query: query ?? "")
            case "settings":
                settings.show()
            case "welcome":
                welcome.show()
            default:
                break
            }
        }
    }

    /// Opening the app again (from Finder or Spotlight) opens the search.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        search.show()
        return false
    }
}
