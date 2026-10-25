// The menu strip: File, Edit, View… attached to the window you're in, like Windows. It sits just above
// the window's title bar (or tucks under it when the window is against the top of the screen), follows the
// window while it moves or resizes, and jumps to the next window when you switch. Drag it to move the
// window; – minimises the window; ✕ quits the app (which asks about unsaved work, as quitting does).
// Following works by asking Accessibility for the front window's frame a few times a second (30 a second
// while the mouse button is down, so a dragged window doesn't leave the strip behind).

import AppKit

@MainActor
final class Strip {
    static let shared = Strip()
    static let height: CGFloat = 26

    private let panel: NSPanel
    private let bar = StripBar()
    private var timer: Timer?
    private var pid: pid_t = 0
    private var window: AXUIElement?
    private var menuBar: MenuBar?
    private var lastFrame: CGRect = .null
    private var fast = false
    private var colorFor: CGRect = .null   // the frame the current colour was sampled at
    private(set) var running = false

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = bar
        bar.onOpen = { [weak self] index, from in self?.open(index, from: from) }
        bar.onDrag = { [weak self] delta in self?.drag(by: delta) }
        bar.onDragEnd = { [weak self] in self?.dragOrigin = nil }
        bar.onMinimise = { [weak self] in self?.minimise() }
        bar.onClose = { [weak self] in self?.quit() }
    }

    func start() {
        guard !running else { return }
        running = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Strip.shared.update(force: true) }
        }
        schedule(fast: false)
        update(force: true)
    }

    /// After a setting changes: read the menus and place the strip again.
    func refresh() {
        colorFor = .null
        update(force: true)
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 30 : 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { Strip.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down != fast {
            fast = down
            schedule(fast: down)
        }
        update(force: false)
    }

    /// Finds the front app's focused window and puts the strip on it, or hides it when there's none.
    private func update(force: Bool) {
        guard running, AX.trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier, !Settings.shared.ignored.contains(app.bundleIdentifier ?? "") else {
            return hide()
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let found = AX.copy(element, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              (AX.string(found, kAXSubroleAttribute) ?? "") == kAXStandardWindowSubrole,
              !AX.bool(found, kAXMinimizedAttribute), !AX.bool(found, "AXFullScreen"),
              let frame = AX.frame(found), frame.width > 220, frame.height > 120 else {
            return hide()
        }
        let newWindow = window.map { !CFEqual($0, found) } ?? true
        window = found
        if force || app.processIdentifier != pid || menuBar == nil {
            pid = app.processIdentifier
            menuBar = MenuBar(pid: pid)
            bar.show(menuBar?.items.map { ($0.title, $0.isAppMenu) } ?? [])
            lastFrame = .null
        }
        guard menuBar != nil else { return hide() }
        if newWindow { colorFor = .null }
        if frame != lastFrame || !panel.isVisible {
            lastFrame = frame
            place(on: frame)
        }
        // Colour from the window's title bar, again when the window changes size (a moved window looks the same).
        if Settings.shared.matchColours, frame.size != colorFor.size, !fast {
            colorFor = frame
            let pid = self.pid
            Task {
                let colour = await WindowColour.sample(pid: pid, frame: frame)
                if pid == self.pid { self.bar.tint = colour }
            }
        } else if !Settings.shared.matchColours {
            bar.tint = nil
        }
    }

    private func hide() {
        if panel.isVisible { panel.orderOut(nil) }
        lastFrame = .null
    }

    /// `frame` is the window in Accessibility coordinates (top-left origin).
    private func place(on frame: CGRect) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let window = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)   // AppKit coordinates
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: window.midX, y: window.maxY - 1)) } ?? NSScreen.main!
        let inset: CGFloat = 8
        var strip = CGRect(x: window.minX + inset, y: window.maxY, width: window.width - inset * 2, height: Self.height)
        let above = Settings.shared.placement == .above && strip.maxY <= screen.visibleFrame.maxY
        if !above {
            // No room above (or chosen): just under the title bar, over the top of the window.
            strip.origin.y = window.maxY - 28 - Self.height
        }
        bar.attachedAbove = above
        panel.setFrame(strip.integral, display: true)
        panel.orderFrontRegardless()
    }

    private func open(_ index: Int, from button: NSView) {
        guard let item = menuBar?.items[safe: index] else { return }
        let mirror = MirrorMenu(source: item.element)
        let menu = mirror.menu()
        withExtendedLifetime(mirror) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: button)
        }
        bar.endOpen()
    }

    // MARK: Window buttons and dragging

    private var dragOrigin: CGPoint?

    /// Moves the window by `delta` (points, AppKit's y-up) from where it was when the drag began.
    private func drag(by delta: CGSize) {
        guard let window, let frame = AX.frame(window) else { return }
        let origin = dragOrigin ?? frame.origin
        dragOrigin = origin
        var point = CGPoint(x: origin.x + delta.width, y: origin.y - delta.height)   // Accessibility's y runs down
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        update(force: false)
    }

    private func minimise() {
        guard let window else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        hide()
    }

    /// Quits the app, as its own Quit does: unsaved documents still get their "save?" question.
    private func quit() {
        NSRunningApplication(processIdentifier: pid)?.terminate()
        hide()
    }
}

/// The strip's look: a row of menu titles on the left, – and ✕ on the right.
final class StripBar: NSView {
    var onOpen: ((Int, NSView) -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnd: (() -> Void)?
    var onMinimise: (() -> Void)?
    var onClose: (() -> Void)?
    var attachedAbove = true { didSet { updateShape() } }
    /// The window's own title-bar colour, when matching it; nil for the standard Mac look.
    var tint: NSColor? { didSet { if tint != oldValue { applyTint() } } }

    private let effect = NSVisualEffectView()
    private let fill = NSView()
    private let stack = NSStackView()
    private let controls = NSStackView()
    private var buttons: [StripButton] = []
    private lazy var minimise = WindowButton(symbol: "minus", help: "Minimise") { [weak self] in self?.onMinimise?() }
    private lazy var close = WindowButton(symbol: "xmark", help: "Quit the app", danger: true) { [weak self] in self?.onClose?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .titlebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        fill.wantsLayer = true
        fill.isHidden = true
        for v in [effect, fill] { addSubview(v) }
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        controls.orientation = .horizontal
        controls.spacing = 0
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        controls.addArrangedSubview(minimise)
        controls.addArrangedSubview(close)
        for v in [stack, controls] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor), controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateShape()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        fill.frame = bounds
    }

    /// Rounded on top when it sits on the window like a tab; all round when it's over the window.
    private func updateShape() {
        for layer in [effect.layer, fill.layer] {
            layer?.cornerRadius = 8
            layer?.maskedCorners = attachedAbove ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    private func applyTint() {
        fill.isHidden = tint == nil
        effect.isHidden = tint != nil
        fill.layer?.backgroundColor = tint?.cgColor
        let ink: NSColor = tint.map { $0.isDark ? .white : .black } ?? .labelColor
        (buttons as [Inked] + [minimise, close]).forEach { $0.ink = ink }
    }

    func show(_ titles: [(String, Bool)]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { i, entry in
            let button = StripButton(title: entry.0, bold: entry.1)
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                button.isOpen = true
                self.onOpen?(i, button)
            }
            button.onDrag = { [weak self] delta in self?.onDrag?(delta) }
            button.onDragEnd = { [weak self] in self?.onDragEnd?() }
            stack.addArrangedSubview(button)
            return button
        }
        applyTint()
    }

    func endOpen() { buttons.forEach { $0.isOpen = false } }

    // Dragging the empty part of the strip moves the window, like a title bar.
    private var dragStart: NSPoint?
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        onDrag?(CGSize(width: now.x - start.x, height: now.y - start.y))
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; onDragEnd?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

protocol Inked: AnyObject { var ink: NSColor { get set } }

/// A menu title. A click opens its menu; pressing and moving drags the window instead.
final class StripButton: NSView, Inked {
    var onPress: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnd: (() -> Void)?
    var isOpen = false { didSet { needsDisplay = true } }
    var ink: NSColor = .labelColor { didSet { label.textColor = ink; needsDisplay = true } }
    private let label: NSTextField
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, bold: Bool) {
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                                     label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                                     heightAnchor.constraint(equalToConstant: Strip.height)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || isOpen else { return }
        ink.withAlphaComponent(isOpen ? 0.18 : 0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Wait to see whether this is a click (open the menu) or the start of a drag (move the window).
    override func mouseDown(with event: NSEvent) {
        let start = NSEvent.mouseLocation
        var dragging = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let now = NSEvent.mouseLocation
            let delta = CGSize(width: now.x - start.x, height: now.y - start.y)
            if next.type == .leftMouseUp { break }
            if !dragging && hypot(delta.width, delta.height) > 3 { dragging = true }
            if dragging { onDrag?(delta) }
        }
        if dragging { onDragEnd?() } else { onPress?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// – and ✕ at the right end; ✕ turns red on hover, as in Windows.
final class WindowButton: NSView, Inked {
    var ink: NSColor = .labelColor { didSet { image.contentTintColor = hovering && danger ? .white : ink } }
    private let image = NSImageView()
    private let action: () -> Void
    private let danger: Bool
    private var hovering = false {
        didSet {
            needsDisplay = true
            image.contentTintColor = hovering && danger ? .white : ink
        }
    }

    init(symbol: String, help: String, danger: Bool = false, action: @escaping () -> Void) {
        self.action = action
        self.danger = danger
        super.init(frame: .zero)
        toolTip = help
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     widthAnchor.constraint(equalToConstant: 34), heightAnchor.constraint(equalToConstant: Strip.height)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        (danger ? NSColor.systemRed : ink.withAlphaComponent(0.1)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSColor {
    var isDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
