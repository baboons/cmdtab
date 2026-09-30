import AppKit

/// Owns a switcher session: which windows are candidates, the query, the
/// selection, and turning key presses into actions.
///
/// Two ways in:
/// - **Hold** (⌘Tab): Tab cycles, typing filters. Releasing ⌘ after picking with
///   Tab/arrows/⌃N/⌃P switches; otherwise (in stay-open mode) the session turns
///   sticky. A quick tap switches to the previous window.
/// - **Sticky** (⌥⌘Tab by default): opens Spotlight-style; type, ↑↓ or ⌃N/⌃P,
///   ↩ or ⌘A to switch.
///
/// The keyboard tap owns the session state machine; this class follows its
/// events and ignores any that belong to an older session.
@MainActor
final class SwitcherController: SwitcherViewDelegate {
    private let tap: KeyboardTap
    private let engine: SearchEngine
    private let panel = SwitcherPanel()
    private var view: SwitcherView { panel.switcherView }

    private(set) var isOpen = false
    /// When the switcher was last closed; used to pick a quiet moment for updates.
    private(set) var lastUsed = Date.distantPast
    private var isVisible = false
    private var mode: KeyboardTap.Mode = .hold
    private var query = ""
    private var candidates: [WindowItem] = []
    private var results: [SearchResult] = []
    private var selected = 0
    private var initialSelection = 0
    private var session: UInt64 = 0
    /// Windows closed and apps quit during this session, hidden until the OS catches up.
    private var removedIDs = Set<UInt64>()
    private var removedPIDs = Set<pid_t>()
    /// The window we last switched to, which is "current" even before macOS
    /// reports the new frontmost app (matters for a fast double ⌘Tab).
    private var lastCommit: (id: UInt64, time: CFAbsoluteTime)?
    private var layout: SwitcherLayout?
    private var screenFrame: CGRect = .zero
    private var panelTop: CGFloat = 0
    private var showWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?

    init(tap: KeyboardTap) {
        self.tap = tap
        self.engine = SearchEngine(learnFile: Settings.learnFileURL)
        view.delegate = self
        tap.handler = { [weak self] event in self?.handle(event) }
        WindowStore.shared.onChange = { [weak self] in self?.storeChanged() }
        ThumbnailService.shared.onUpdate = { [weak self] id, image in self?.view.updateThumbnail(id, image) }
    }

    // MARK: - Events

    private func handle(_ event: KeyboardTap.Event) {
        switch event {
        case let .open(session, mode, reverse):
            open(session: session, mode: mode, reverse: reverse)
        case let .key(session, code, flags, isRepeat):
            guard isOpen, session == self.session else { return }
            if !isVisible { show() }
            handleKey(code: code, flags: flags, isRepeat: isRepeat)
        case let .release(session, staysOpen):
            guard isOpen, session == self.session, mode == .hold else { return }
            // The tap already decided: a quick tap or a window picked with
            // Tab/arrows/⌃N/⌃P switches; otherwise the session continues as a search.
            if staysOpen {
                mode = .sticky
                if !isVisible { show() }
                view.setHints(mode: .sticky, trigger: Settings.shared.trigger, releaseSwitches: false)
            } else {
                commit()
            }
        }
    }

    func clearLearning() {
        engine.clearLearning()
    }

    func openSticky() {
        guard !isOpen else { return }
        open(session: tap.forceActivate(), mode: .sticky, reverse: false)
    }

    private func open(session: UInt64, mode: KeyboardTap.Mode, reverse: Bool) {
        if isOpen { close() }
        self.session = session
        removedIDs.removeAll()
        removedPIDs.removeAll()
        candidates = Self.filteredItems()
        guard !candidates.isEmpty else {
            tap.deactivate(session: session)
            return
        }
        isOpen = true
        self.mode = mode
        query = ""
        engine.setItems(candidates)
        results = engine.search("")

        let currentIsFirst: Bool
        if let lastCommit, CFAbsoluteTimeGetCurrent() - lastCommit.time < 1.5 {
            currentIsFirst = results.first?.item.id == lastCommit.id
        } else {
            currentIsFirst = results.first?.item.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        initialSelection = currentIsFirst && results.count > 1 ? 1 : 0
        selected = reverse ? results.count - 1 : initialSelection
        WindowStore.shared.reconcile()

        let screen = Self.activeScreen()
        screenFrame = screen.visibleFrame
        let settings = Settings.shared
        let layout = SwitcherLayout.make(style: settings.style, scale: settings.previewSize.scale,
                                         itemCount: candidates.count, screen: screenFrame, hints: settings.showHints)
        self.layout = layout
        view.begin(layout: layout, mode: mode, trigger: settings.trigger,
                   releaseSwitches: settings.releaseBehavior == .switchWindow)
        view.prune(keeping: Set(candidates.map(\.id)))

        // Refresh previews for everything that could be on screen, best first.
        if settings.style == .previews {
            let scale = screen.backingScaleFactor
            let visible = candidates.prefix(layout.columns * layout.maxRows).filter { !$0.isWindowless }.map(\.windowID)
            ThumbnailService.shared.refresh(visible, maxPixels: CGSize(width: layout.thumbSize.width * scale,
                                                                     height: layout.thumbSize.height * scale))
        }
        let delay = mode == .hold ? settings.appearDelay / 1000 : 0
        if delay <= 0 {
            show()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.show() }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func show() {
        guard isOpen, !isVisible, let layout else { return }
        isVisible = true
        showWork?.cancel()
        let height = layout.height(for: results.count)
        let x = (screenFrame.midX - layout.width / 2).rounded()
        // Anchor the top edge: as results narrow, the panel shrinks upwards.
        panelTop = (screenFrame.midY + layout.height(for: candidates.count) / 2).rounded()
        panelTop = min(panelTop, screenFrame.maxY - 20)
        panel.setFrame(CGRect(x: x, y: panelTop - height, width: layout.width, height: height), display: false)
        view.update(query: query, results: results, selected: selected, animated: false)
        panel.orderFrontRegardless()
        // The panel can stay open without holding a key, so a click anywhere
        // else dismisses it (global monitors only see other apps' events).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        lastUsed = Date()
        showWork?.cancel()
        showWork = nil
        isOpen = false
        isVisible = false
        tap.deactivate(session: session)
        panel.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Keys

    private func handleKey(code: UInt16, flags: CGEventFlags, isRepeat: Bool) {
        let shift = flags.contains(.maskShift)
        let command = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)
        let control = flags.contains(.maskControl)
        let trigger = Settings.shared.trigger
        // Modifiers pressed for this key, without the trigger held since ⌘Tab.
        let chord = mode == .hold ? flags.subtracting(trigger.flags) : flags
        let columns = layout?.style == .previews ? layout?.columns ?? 1 : 1

        switch code {
        case KeyCode.tab: move(shift ? -1 : 1)
        case KeyCode.right: move(1)
        case KeyCode.left: move(-1)
        case KeyCode.down: move(columns, wrap: columns == 1)
        case KeyCode.up: move(-columns, wrap: columns == 1)
        case KeyCode.home: select(0)
        case KeyCode.end: select(results.count - 1)
        case KeyCode.returnKey, KeyCode.keypadEnter: commit()
        case KeyCode.escape:
            if query.isEmpty { close() } else { setQuery("") }
        case KeyCode.delete:
            guard !query.isEmpty else { return }
            if option || (command && mode == .sticky) {
                setQuery(Self.deletingLastWord(query, all: command && mode == .sticky))
            } else {
                setQuery(String(query.dropLast()))
            }
        case KeyCode.space:
            if !query.isEmpty, !query.hasSuffix(" ") { setQuery(query + " ") }
        default:
            if let step = KeyCode.step(for: code, chord: chord) { return move(step) }
            // ⌘A switches like ↩, unless ⌘ is the held trigger and A is just typing.
            if chord.contains(.maskCommand), KeyTranslator.shared.character(for: code, shift: false)?.lowercased() == "a" {
                return commit()
            }
            // Window actions: ⇧+key while holding the trigger, ⌘+key in sticky mode.
            let actionModifier = mode == .hold ? shift : command
            if actionModifier, !isRepeat, let action = Self.action(for: code) {
                perform(action)
                return
            }
            // Held trigger modifiers are expected in hold mode; anything else is a shortcut, not text.
            let heldControl = control && !(mode == .hold && trigger == .control)
            if heldControl || (mode == .sticky && command) { return }
            guard let char = KeyTranslator.shared.character(for: code, shift: false),
                  char.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return }
            setQuery(query + char.lowercased())
        }
    }

    private static func action(for code: UInt16) -> WindowAction? {
        switch KeyTranslator.shared.character(for: code, shift: false)?.lowercased() {
        case "w": .close
        case "m": .minimize
        case "q": .quitApp
        case "h": .hideApp
        case "f": .toggleFullscreen
        default: nil
        }
    }

    private static func deletingLastWord(_ s: String, all: Bool) -> String {
        if all { return "" }
        var t = s
        while t.last == " " { t.removeLast() }
        while let last = t.last, last != " " { t.removeLast() }
        return t
    }

    private func move(_ delta: Int, wrap: Bool = true) {
        guard !results.isEmpty else { return }
        var next = selected + delta
        if wrap {
            next = ((next % results.count) + results.count) % results.count
        } else {
            next = max(0, min(results.count - 1, next))
        }
        select(next)
    }

    private func select(_ index: Int) {
        guard !results.isEmpty else { return }
        selected = max(0, min(results.count - 1, index))
        if isVisible { view.updateSelection(selected) }
    }

    private func setQuery(_ newQuery: String) {
        query = newQuery
        results = engine.search(query)
        selected = query.isEmpty ? min(initialSelection, max(results.count - 1, 0)) : 0
        render(animated: true)
    }

    private func render(animated: Bool) {
        guard isVisible, let layout else { return }
        let height = layout.height(for: results.count)
        if panel.frame.height != height {
            var frame = panel.frame
            frame.origin.y = panelTop - height
            frame.size.height = height
            panel.setFrame(frame, display: false)
        }
        view.update(query: query, results: results, selected: selected, animated: animated)
    }

    // MARK: - Actions

    private func commit() {
        guard isOpen else { return }
        let item = results.indices.contains(selected) ? results[selected].item : nil
        let usedQuery = query
        close()
        guard let item else { return }
        WindowActions.focus(item)
        WindowStore.shared.noteActivated(item)
        lastCommit = (item.id, CFAbsoluteTimeGetCurrent())
        if !usedQuery.trimmingCharacters(in: .whitespaces).isEmpty, Settings.shared.learnFromSelections {
            engine.record(query: usedQuery, for: item)
        }
    }

    private func perform(_ action: WindowAction) {
        guard results.indices.contains(selected) else { return }
        let item = results[selected].item
        WindowActions.perform(action, on: item)
        switch action {
        case .close where !item.isWindowless:
            WindowStore.shared.forget(item)
            removedIDs.insert(item.id)
            candidates.removeAll { $0.id == item.id }
        case .quitApp:
            removedPIDs.insert(item.pid)
            candidates.removeAll { $0.pid == item.pid }
        default:
            return
        }
        guard !candidates.isEmpty else { return close() }
        let keepIndex = selected
        engine.setItems(candidates)
        results = engine.search(query)
        selected = min(keepIndex, max(results.count - 1, 0))
        render(animated: true)
    }

    // MARK: - SwitcherViewDelegate

    func switcherView(didHover index: Int) {
        guard results.indices.contains(index), index != selected else { return }
        selected = index
        view.updateSelection(index)
    }

    func switcherView(didClick index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        commit()
    }

    func switcherView(didRequest action: WindowAction, at index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
        view.updateSelection(index)
        perform(action)
    }

    // MARK: - Model

    /// Merges store updates into the open session without reordering what
    /// the user is looking at: existing items keep their place, new windows
    /// are appended and closed ones disappear.
    private func storeChanged() {
        guard isOpen else { return }
        let fresh = Self.filteredItems().filter { !removedIDs.contains($0.id) && !removedPIDs.contains($0.pid) }
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(candidates.map(\.id))
        let merged = candidates.compactMap { byID[$0.id] } + fresh.filter { !known.contains($0.id) }
        guard !merged.isEmpty else { return close() }
        let selectedID = results.indices.contains(selected) ? results[selected].item.id : nil
        candidates = merged
        engine.setItems(candidates)
        results = engine.search(query)
        selected = results.firstIndex { $0.item.id == selectedID } ?? min(selected, max(results.count - 1, 0))
        render(animated: true)
    }

    private static func filteredItems() -> [WindowItem] {
        let s = Settings.shared
        let spaces = WindowStore.shared.currentSpaces
        return WindowStore.shared.items.filter { item in
            if item.isAppHidden && !s.showHiddenApps { return false }
            if item.isWindowless { return s.showWindowlessApps }
            if item.isMinimized { return s.showMinimized }
            if !s.showOtherSpaces, !spaces.isEmpty, !item.spaces.isEmpty, spaces.isDisjoint(with: item.spaces) {
                return false
            }
            return true
        }
    }

    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
