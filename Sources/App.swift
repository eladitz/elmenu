// Elmenu: the menu bar of the app you're in, attached to its window, like Windows' File Edit View.
// A menu bar app; it needs the Accessibility permission to read and use other apps' menus.

import AppKit
import ServiceManagement

/// Built for the Mac App Store (`./build.sh appstore`): sandboxed, and the Store does the updating.
enum Distribution {
    #if APPSTORE
    static let appStore = true
    #else
    static let appStore = false
    #endif
}

@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum Placement: String { case above, under }

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    var placement: Placement {
        get { Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .above }
        set { d.set(newValue.rawValue, forKey: "placement") }
    }
    var ignored: [String] {
        get { d.stringArray(forKey: "ignored") ?? [] }
        set { d.set(newValue, forKey: "ignored") }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var waiting: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Elmenu")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        Donation.usageLine = { "You've used it on \($0) different days so far." }
        Donation.start()
        #if !APPSTORE
        Updater.start()
        #endif
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Donation.recordDay() }
        }
        if AX.trusted { begin() } else { askPermission() }
    }

    private func begin() {
        if Settings.shared.enabled { Strip.shared.start() }
    }

    // MARK: Permission

    private func askPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Elmenu to use other apps' menus"
        alert.informativeText = "To show each app's File, Edit, View… on its window, macOS needs you to switch Elmenu on under Accessibility, once. Elmenu only reads menus and chooses the items you click; it doesn't read what's in your windows."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            AX.askForTrust()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        waiting?.invalidate()
        waiting = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard AX.trusted else { return }
                timer.invalidate()
                (NSApp.delegate as? AppDelegate)?.begin()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, on: Bool? = nil, key: String = "") -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            return i
        }
        if !AX.trusted {
            _ = add("Allow Elmenu in Accessibility…", #selector(permission))
            menu.addItem(.separator())
        }
        _ = add("Menus on Windows", #selector(toggle), on: Settings.shared.enabled)
        menu.addItem(.separator())
        _ = add("Above the Title Bar", #selector(placeAbove), on: Settings.shared.placement == .above)
        _ = add("Under the Title Bar", #selector(placeUnder), on: Settings.shared.placement == .under)
        menu.addItem(.separator())
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let i = add("Not for \(app.localizedName ?? "This App")", #selector(toggleIgnore(_:)), on: Settings.shared.ignored.contains(id))
            i.representedObject = id
        }
        _ = add("Open at Login", #selector(toggleLogin), on: Settings.shared.launchAtLogin)
        menu.addItem(.separator())
        if !Distribution.appStore { _ = add("Check for Updates…", #selector(updates)) }
        _ = add("Support Elmenu on Ko-fi…", #selector(donate))
        _ = add("Elmenu Website", #selector(website))
        let quit = menu.addItem(withTitle: "Quit Elmenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    @objc private func permission() { askPermission() }

    @objc private func toggle() {
        Settings.shared.enabled.toggle()
        if Settings.shared.enabled { Strip.shared.start() } else { Strip.shared.stop() }
    }

    @objc private func placeAbove() { Settings.shared.placement = .above; Strip.shared.refresh() }
    @objc private func placeUnder() { Settings.shared.placement = .under; Strip.shared.refresh() }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = Settings.shared.ignored
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        Settings.shared.ignored = list
        Strip.shared.refresh()
    }

    @objc private func toggleLogin() { Settings.shared.launchAtLogin.toggle() }
    @objc private func updates() { Task { await Updater.check(manual: true) } }
    @objc private func donate() { NSWorkspace.shared.open(Donation.page) }
    @objc private func website() { NSWorkspace.shared.open(URL(string: "https://ai.itzkin.com/elmenu.html")!) }
}

@main
enum Entry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
