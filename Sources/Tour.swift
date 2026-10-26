// `--tour`: Elmenu at work, for the website's demo video. It opens a demo document window of its own (so none of
// yours are shown), gives itself an ordinary File, Edit, Format, View menu bar, and lets the strip do the rest:
// it appears on the window, follows it as it moves, and opens the menus one after another. Then it quits.

import AppKit

@MainActor
enum Tour {
    static var running = false
    static var screen: NSScreen { NSScreen.screens.first! }
    private static var keep: [NSWindow] = []

    static func run() {
        running = true
        stage()
        NSApp.mainMenu = demoMenu()
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 340, y: screen.frame.minY + 200, width: 900, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Letter.rtf"
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        text.textContainerInset = NSSize(width: 40, height: 36)
        text.font = .systemFont(ofSize: 17)
        text.string = "Dear Alex,\n\nThank you for the quick reply. I've filled in the form and attached it.\nLet me know if anything else is needed.\n\nBest wishes,"
        window.contentView = text
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        keep.append(window)
        NSApp.activate(ignoringOtherApps: true)
        Strip.shared.start()
        Task {
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            await pause(2.5)
            Strip.shared.tourMenus([1, 2, 3, 4], seconds: 1.6)   // File, Edit, Format, View
            await pause(1)
            // The strip follows the window.
            for step in 0..<30 {
                var f = window.frame
                f.origin.x += 6
                f.origin.y += step < 15 ? 4 : -4
                window.setFrame(f, display: true)
                await pause(0.04)
            }
            await pause(1.5)
            Strip.shared.tourMenus([2], seconds: 1.8)
            await pause(1)
            NSApp.terminate(nil)
        }
    }

    private static func demoMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, String)]) {
            let m = NSMenu(title: title)
            for (name, key) in items {
                if name == "-" { m.addItem(.separator()); continue }
                m.addItem(withTitle: name, action: #selector(NSText.selectAll(_:)), keyEquivalent: key)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        menu("Elmenu", [("About Elmenu", ""), ("-", ""), ("Quit Elmenu", "q")])
        menu("File", [("New", "n"), ("Open…", "o"), ("Open Recent", ""), ("-", ""), ("Close", "w"), ("Save", "s"), ("Duplicate", ""), ("-", ""), ("Print…", "p")])
        menu("Edit", [("Undo Typing", "z"), ("Redo", "Z"), ("-", ""), ("Cut", "x"), ("Copy", "c"), ("Paste", "v"), ("Select All", "a"), ("-", ""), ("Find…", "f")])
        menu("Format", [("Font", ""), ("Text", ""), ("-", ""), ("Make Plain Text", "T"), ("Wrap to Page", "")])
        menu("View", [("Actual Size", "0"), ("Zoom In", "+"), ("Zoom Out", "-"), ("-", ""), ("Show Ruler", "r")])
        menu("Window", [("Minimize", "m"), ("Zoom", ""), ("-", ""), ("Bring All to Front", "")])
        menu("Help", [("Elmenu Help", "?")])
        return main
    }

    /// A plain dark backdrop over the recorded display, behind the demo window.
    private static func stage() {
        let w = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.level = .normal
        w.orderFrontRegardless()
        keep.append(w)
    }
}
