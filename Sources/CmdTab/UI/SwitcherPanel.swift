import AppKit

/// A borderless, non-activating floating panel. It never becomes key, so
/// showing it never steals focus from the app you're switching away from;
/// all keyboard input arrives through the event tap instead.
final class SwitcherPanel: NSPanel {
    let switcherView = SwitcherView()
    private static let cornerRadius: CGFloat = 26

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = Self.makeBackground(containing: switcherView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static func makeBackground(containing content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }
}
