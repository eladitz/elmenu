// The menu strip: File, Edit, View… attached to the window you're in, like Windows. It sits just above
// the window's title bar (or tucks under it when the window is against the top of the screen), follows the
// window while it moves or resizes, and jumps to the next window when you switch.
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
    private var menuBar: MenuBar?
    private var lastFrame: CGRect = .null
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
    func refresh() { update(force: true) }

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

    private var fast = false

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
        guard let window = AX.copy(element, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              (AX.string(window, kAXSubroleAttribute) ?? "") == kAXStandardWindowSubrole,
              !AX.bool(window, kAXMinimizedAttribute), !AX.bool(window, "AXFullScreen"),
              let frame = AX.frame(window), frame.width > 220, frame.height > 120 else {
            return hide()
        }
        if force || app.processIdentifier != pid || menuBar == nil {
            pid = app.processIdentifier
            menuBar = MenuBar(pid: pid)
            bar.show(menuBar?.items.map { ($0.title, $0.isAppMenu) } ?? [])
            lastFrame = .null
        }
        guard menuBar != nil else { return hide() }
        if frame != lastFrame || !panel.isVisible {
            lastFrame = frame
            place(on: frame)
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
}

/// The row of menu titles, drawn like a menu bar attached to the window.
final class StripBar: NSView {
    var onOpen: ((Int, NSView) -> Void)?
    var attachedAbove = true { didSet { needsLayout = true; updateShape() } }
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private var buttons: [StripButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .titlebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)])
        updateShape()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rounded on top when it sits on the window like a tab; plain when it's over the window.
    private func updateShape() {
        effect.layer?.cornerRadius = 8
        effect.layer?.maskedCorners = attachedAbove ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
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
            stack.addArrangedSubview(button)
            return button
        }
    }

    func endOpen() { buttons.forEach { $0.isOpen = false } }
}

final class StripButton: NSView {
    var onPress: (() -> Void)?
    var isOpen = false { didSet { needsDisplay = true } }
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
        NSColor.labelColor.withAlphaComponent(isOpen ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress?() }
    // A click in a panel that doesn't activate its app still reaches the view.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
