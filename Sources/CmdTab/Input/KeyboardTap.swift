import AppKit
import os

/// A session-level CGEventTap on a dedicated high-priority thread.
///
/// The tap thread owns the switcher's session state machine, so it can
/// decide synchronously whether to swallow an event, including what
/// releasing the trigger modifier means. It then forwards intent to the main
/// thread. Every session has an id, so a late message from the main thread
/// about an old session can never end a newer one.
final class KeyboardTap {
    enum Mode { case hold, sticky }

    enum Event {
        /// Open the switcher. `reverse` when opened with ⇧.
        case open(session: UInt64, mode: Mode, reverse: Bool)
        case key(session: UInt64, code: UInt16, flags: CGEventFlags, isRepeat: Bool)
        /// The trigger modifier was released in hold mode. If `staysOpen`, the
        /// session continues in sticky mode (keep searching); otherwise it has
        /// ended and the main thread should switch to the selected window.
        case release(session: UInt64, staysOpen: Bool)
    }

    struct Config {
        var trigger: CGEventFlags = .maskCommand
        var searchCombo: KeyCombo?
        /// Releasing the trigger keeps the switcher open, unless the user
        /// picked a window with Tab/arrows/⌃N/⌃P or it was a quick tap.
        var stayOpenOnRelease = false
        /// How long hold mode waits before showing the panel.
        var appearDelay: TimeInterval = 0.09
    }

    fileprivate struct State {
        var active = false
        var mode = Mode.hold
        var enabled = true
        var session: UInt64 = 0
        var openedAt: CFAbsoluteTime = 0
        /// Any key since opening; the main thread shows the panel on the first key.
        var sawKey = false
        /// Selection moved with Tab/arrows/⌃N/⌃P since the query last changed.
        var picked = false
        var config = Config()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var tap: CFMachPort?
    private var thread: Thread?

    /// Called on the main thread.
    var handler: ((Event) -> Void)?

    var isRunning: Bool { tap != nil }

    /// False if the tap exists but macOS has disabled it.
    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Creates the tap. Fails without Accessibility permission.
    func start() -> Bool {
        guard tap == nil else { return true }
        // Load the keyboard layout here on the main thread; the tap thread only translates.
        _ = KeyTranslator.shared
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyboardTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "CmdTab.KeyboardTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    func update(_ config: Config) {
        state.withLock { $0.config = config }
    }

    /// Enables or disables interception entirely (e.g. while recording a shortcut).
    func setEnabled(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            if !enabled { $0.active = false }
        }
    }

    /// Starts a sticky session without a key press (e.g. from the menu bar).
    func forceActivate() -> UInt64 {
        state.withLock { s in
            s.begin(mode: .sticky, reverse: false)
            return s.session
        }
    }

    /// Called by the main thread when session `session` closes for any reason.
    func deactivate(session: UInt64) {
        state.withLock { s in
            if s.session == session { s.active = false }
        }
    }

    // MARK: - Tap thread

    private func post(_ events: [Event]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for event in events { self?.handler?(event) }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // We may have missed the modifier release while disabled.
            let flags = CGEventSource.flagsState(.combinedSessionState)
            post(state.withLock { s in s.releaseIfNeeded(flags: flags).map { [$0] } ?? [] })
            return pass

        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let (swallow, events) = state.withLock { s -> (Bool, [Event]) in
                guard s.enabled else { return (false, []) }
                if s.active {
                    var events: [Event] = []
                    // A key without the trigger held means we missed its release.
                    if let release = s.releaseIfNeeded(flags: flags) {
                        events.append(release)
                        if !s.active { return (false, events) }
                    }
                    s.noteKey(code, flags: flags)
                    events.append(.key(session: s.session, code: code, flags: flags, isRepeat: isRepeat))
                    return (true, events)
                }
                let mods = flags.intersection(KeyCombo.relevantFlags)
                if let combo = s.config.searchCombo, combo.keyCode == code, combo.flags == mods {
                    s.begin(mode: .sticky, reverse: false)
                    return (true, [.open(session: s.session, mode: .sticky, reverse: false)])
                }
                if code == KeyCode.tab, !isRepeat {
                    let trigger = s.config.trigger
                    let others = mods.subtracting([.maskShift]).subtracting(trigger)
                    if mods.contains(trigger), others.isEmpty {
                        let reverse = mods.contains(.maskShift)
                        s.begin(mode: .hold, reverse: reverse)
                        return (true, [.open(session: s.session, mode: .hold, reverse: reverse)])
                    }
                }
                return (false, [])
            }
            post(events)
            return swallow ? nil : pass

        case .keyUp:
            let swallow = state.withLock { $0.enabled && $0.active }
            return swallow ? nil : pass

        case .flagsChanged:
            let flags = event.flags
            post(state.withLock { s in s.releaseIfNeeded(flags: flags).map { [$0] } ?? [] })
            return pass

        default:
            return pass
        }
    }
}

private extension KeyboardTap.State {
    /// Releasing the trigger this soon after ⌘Tab, with no other key, is a tap
    /// that flips to the previous window, even if the panel already appeared.
    /// Real taps often take 150-250 ms, well past the appear delay.
    static let quickTap: CFTimeInterval = 0.3

    mutating func begin(mode: KeyboardTap.Mode, reverse: Bool) {
        session &+= 1
        active = true
        self.mode = mode
        openedAt = CFAbsoluteTimeGetCurrent()
        sawKey = false
        picked = reverse
    }

    /// Tracks whether the current selection was deliberately picked.
    mutating func noteKey(_ code: UInt16, flags: CGEventFlags) {
        sawKey = true
        let chord = mode == .hold ? flags.subtracting(config.trigger) : flags
        switch code {
        case KeyCode.tab, KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down, KeyCode.home, KeyCode.end:
            picked = true
        case _ where KeyCode.step(for: code, chord: chord) != nil:
            picked = true
        default:
            // ⇧+key is a window action in hold mode and leaves the selection alone;
            // anything else edits the query, which re-ranks and resets the pick.
            if !flags.contains(.maskShift) { picked = false }
        }
    }

    /// If a hold session's trigger is no longer held, ends it or turns it
    /// sticky, and returns the event describing what happened.
    mutating func releaseIfNeeded(flags: CGEventFlags) -> KeyboardTap.Event? {
        guard active, mode == .hold, !flags.contains(config.trigger) else { return nil }
        let held = CFAbsoluteTimeGetCurrent() - openedAt
        let tap = !sawKey && held < max(config.appearDelay, Self.quickTap)
        let staysOpen = config.stayOpenOnRelease && !tap && !picked
        if staysOpen { mode = .sticky } else { active = false }
        return .release(session: session, staysOpen: staysOpen)
    }
}
