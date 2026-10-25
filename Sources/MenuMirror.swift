// Another app's menu bar, through the Accessibility API: its top-level titles, and each menu rebuilt as a
// real NSMenu when it's opened (read fresh every time, so enabled items, checkmarks and lists like
// "Open Recent" are current). Choosing an item presses the app's own menu item, so it does exactly what
// choosing it at the top of the screen does.

import AppKit

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? { copy(element, attribute) as? String }
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool { (copy(element, attribute) as? Bool) ?? false }
    static func children(_ element: AXUIElement) -> [AXUIElement] { copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = copy(element, kAXPositionAttribute), let s = copy(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

/// One app's menu bar.
struct MenuBar {
    struct Item {
        let title: String
        let element: AXUIElement   // the AXMenuBarItem
        let isAppMenu: Bool
    }

    let pid: pid_t
    let items: [Item]

    /// The app's menu titles, without the Apple menu (that one is the system's, not the app's).
    init?(pid: pid_t) {
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        guard let bar = AX.copy(app, kAXMenuBarAttribute) else { return nil }
        let all = AX.children(bar as! AXUIElement)
        var found: [Item] = []
        for (i, element) in all.enumerated() {
            guard let title = AX.string(element, kAXTitleAttribute), !title.isEmpty else { continue }
            if i == 0 && title == "Apple" { continue }
            found.append(Item(title: title, element: element, isAppMenu: found.isEmpty))
        }
        guard !found.isEmpty else { return nil }
        items = found
    }
}

/// Builds NSMenus that mirror an app's AX menus, opening submenus lazily as you reach them.
final class MirrorMenu: NSObject, NSMenuDelegate {
    private let source: AXUIElement          // the AXMenuBarItem or AXMenuItem whose menu this is
    private var keep: [MirrorMenu] = []      // submenu delegates, alive while the menu is

    init(source: AXUIElement) {
        self.source = source
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        fill(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private static let wanted = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
                                 kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXChildrenAttribute] as CFArray

    /// Only this menu's own items: each item's details in one request, and submenus left empty until you
    /// reach them (reading a whole menu tree up front is what made opening a menu slow).
    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        keep = []
        guard let axMenu = AX.children(source).first else { return }
        for element in AX.children(axMenu) {
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [Any], values.count == 7 else { continue }
            let title = values[0] as? String ?? ""
            if title.isEmpty {
                // Untitled, disabled items are separators; untitled enabled ones are custom views we can't show.
                if !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = element
            item.isEnabled = values[1] as? Bool ?? true
            if let mark = values[2] as? String, !mark.isEmpty { item.state = .on }
            let modifiers = values[4] as? Int ?? 0
            if let key = values[3] as? String, !key.isEmpty {
                item.keyEquivalent = key.lowercased()
                item.keyEquivalentModifierMask = Self.modifiers(modifiers, key: key)
            } else if let glyph = values[5] as? Int, let key = Self.glyphKey(glyph) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = Self.modifiers(modifiers, key: key)
            }
            if let children = values[6] as? [AXUIElement], !children.isEmpty {
                let mirror = MirrorMenu(source: element)
                keep.append(mirror)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.delegate = mirror   // filled by menuNeedsUpdate when it opens
                item.submenu = submenu
                item.action = nil
            }
            menu.addItem(item)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let element = sender.representedObject else { return }
        let target = element as! AXUIElement
        // After our menu has closed, so the app gets the press as if its own menu had been used.
        DispatchQueue.main.async { AXUIElementPerformAction(target, kAXPressAction as CFString) }
    }

    /// Accessibility's modifier bits: Command is implied unless bit 3 says otherwise.
    static func modifiers(_ bits: Int, key: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if bits & 8 == 0 { flags.insert(.command) }
        if bits & 1 != 0 { flags.insert(.shift) }
        if bits & 2 != 0 { flags.insert(.option) }
        if bits & 4 != 0 { flags.insert(.control) }
        return flags
    }

    /// The few special keys menus show as glyphs (Delete, Return, arrows, Escape).
    static func glyphKey(_ glyph: Int) -> String? {
        switch glyph {
        case 0x17: return "\u{8}"
        case 0x0B: return "\r"
        case 0x1B: return "\u{1B}"
        case 0x64: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 0x65: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 0x68: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 0x6A: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: return nil
        }
    }
}
