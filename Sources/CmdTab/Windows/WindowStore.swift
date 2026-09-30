import AppKit
import ApplicationServices

private func axObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    WindowStore.shared.handle(notification: notification as String, element: element, refcon: refcon)
}

/// Keeps a live model of every window on the system, updated by
/// Accessibility notifications, so that opening the switcher is just
/// rendering an in-memory list: no IPC on the hot path.
///
/// Threading: everything prefixed `ax` / marked "AX thread" runs on `thread`.
/// `items`, `currentSpaces` and `onChange` belong to the main thread.
final class WindowStore {
    static let shared = WindowStore()

    // MARK: Main thread

    private(set) var items: [WindowItem] = []
    private(set) var currentSpaces: Set<UInt64> = []
    var onChange: (() -> Void)?

    // MARK: AX thread

    private final class TrackedApp {
        let element: AXUIElement
        var info: AppInfo
        var observer: AXObserver?
        var notificationsRegistered = false
        var attempts = 0
        var lastActivation: UInt64 = 0

        init(_ info: AppInfo) {
            self.info = info
            self.element = AXUIElementCreateApplication(info.pid)
            AXUIElementSetMessagingTimeout(element, 1.0)
        }
    }

    private final class TrackedWindow {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        var title: String
        var isMinimized: Bool
        var isFullscreen: Bool
        var spaces: [UInt64]
        var lastFocus: UInt64 = 0

        init(id: CGWindowID, pid: pid_t, element: AXUIElement, attributes: WindowAttributes) {
            self.id = id
            self.pid = pid
            self.element = element
            self.title = attributes.title
            self.isMinimized = attributes.isMinimized
            self.isFullscreen = attributes.isFullscreen
            self.spaces = Private.spaces(for: id)
        }
    }

    private let thread = RunLoopThread(name: "CmdTab.Accessibility", qos: .userInitiated)
    private var apps: [pid_t: TrackedApp] = [:]
    private var windows: [CGWindowID: TrackedWindow] = [:]
    private var clock: UInt64 = 0
    private var frontmostPID: pid_t = 0
    private var axCurrentSpaces: Set<UInt64> = []
    private var publishPending = false
    /// Dock badge labels by bundle id (or "name:<App>" when there is none).
    private var badges: [String: String] = [:]
    private var bundleIDsByURL: [URL: String] = [:]
    private var started = false

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowResizedNotification,
    ]

    // MARK: - Lifecycle (main thread)

    func start() {
        guard !started else { return }
        started = true
        thread.startAndWait()
        // The per-element timeout doesn't carry over to window elements; set the
        // global default so one hung app can't stall the AX thread for ~6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        let center = NSWorkspace.shared.notificationCenter
        func app(_ note: Notification) -> NSRunningApplication? {
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let running = app(note), Self.isCandidate(running) else { return }
            let info = AppInfo(running)
            thread.perform { self.addApp(info, isLaunch: true) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let pid = app(note)?.processIdentifier else { return }
            thread.perform { self.removeApp(pid) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let running = app(note) else { return }
            let pid = running.processIdentifier
            let info = Self.isCandidate(running) ? AppInfo(running) : nil
            thread.perform { self.appActivated(pid, info: info) }
        }
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let pid = app(note)?.processIdentifier else { return }
                thread.perform { self.setHidden(pid, hidden) }
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            thread.perform { self.spaceChanged() }
        }

        let running = NSWorkspace.shared.runningApplications.filter(Self.isCandidate).map(AppInfo.init)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        thread.perform { self.bootstrap(running, frontmost: front) }
    }

    static func isCandidate(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && !app.isTerminated
            && app.activationPolicy != .prohibited
    }

    /// Optimistically moves `item` to the front of the MRU list. Called when
    /// the user switches through us, before the OS confirms the focus change,
    /// so a quick second ⌘Tab already sees the right order.
    func noteActivated(_ item: WindowItem) {
        let top = (items.map(\.lastFocus).max() ?? 0) + 1
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].lastFocus = top
            items.sort(by: Self.mruOrder)
        }
        thread.perform { [self] in
            frontmostPID = item.pid
            if item.isWindowless {
                clock += 1
                apps[item.pid]?.lastActivation = clock
            } else {
                bump(item.windowID)
            }
        }
    }

    /// Re-reads Space membership; called when the switcher opens.
    /// Called when the switcher opens. Catches what notifications missed:
    /// apps that are gone, windows the window server no longer has, and
    /// windows an app closed or hid without destroying them (common for
    /// Mail and Electron apps). Publishes only if something changed.
    func reconcile() {
        thread.perform { [self] in
            var changed = false
            for pid in Array(apps.keys) where kill(pid, 0) != 0 && errno == ESRCH {
                removeApp(pid)
                changed = true
            }
            guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
            var alive = Set<CGWindowID>()
            var onScreen = Set<CGWindowID>()
            for info in list {
                guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
                alive.insert(id)
                if info[kCGWindowIsOnscreen as String] as? Bool == true { onScreen.insert(id) }
            }
            let current = Private.currentSpaces()
            if current != axCurrentSpaces {
                axCurrentSpaces = current
                changed = true
            }
            for (id, window) in Array(windows) {
                guard alive.contains(id) else {
                    windows.removeValue(forKey: id)
                    changed = true
                    continue
                }
                guard Private.canQuerySpaces else { continue }
                let spaces = Private.spaces(for: id)
                if spaces != window.spaces {
                    window.spaces = spaces
                    changed = true
                }
                // A closed-but-retained window is on no Space; a hidden one claims a
                // visible Space yet isn't on screen. Minimized windows and hidden
                // apps look similar, so rule those out (re-asking AX to be sure).
                let appHidden = apps[window.pid]?.info.isHidden ?? false
                let closed = spaces.isEmpty
                let hidden = !spaces.isEmpty && !current.isDisjoint(with: spaces) && !onScreen.contains(id)
                guard closed || hidden, !window.isMinimized, !appHidden,
                      Self.value(window.element, kAXMinimizedAttribute) as? Bool != true else { continue }
                windows.removeValue(forKey: id)
                changed = true
            }
            refreshBadges()
            if changed { schedulePublish() }
        }
    }

    /// Reads unread badges from the Dock, which exposes each icon's label as
    /// AXStatusLabel. Dock items are matched to apps by bundle id (their URLs
    /// can differ from the app's, e.g. Safari lives in a system cryptex).
    private func refreshBadges() {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return }
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        guard let list = (Self.value(dock, kAXChildrenAttribute) as? [AXUIElement])?
                .first(where: { Self.value($0, kAXRoleAttribute) as? String == kAXListRole }),
              let items = Self.value(list, kAXChildrenAttribute) as? [AXUIElement] else { return }
        let names = [kAXSubroleAttribute, "AXStatusLabel", kAXURLAttribute, kAXTitleAttribute] as CFArray
        var fresh: [String: String] = [:]
        for item in items {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, names, [], &values) == .success,
                  let v = values as? [AnyObject], v.count == 4,
                  v[0] as? String == "AXApplicationDockItem",
                  let label = v[1] as? String, !label.isEmpty else { continue }
            if let url = v[2] as? URL, let id = bundleID(for: url) {
                fresh[id] = label
            } else if let title = v[3] as? String {
                fresh["name:" + title] = label
            }
        }
        if fresh != badges {
            badges = fresh
            schedulePublish()
        }
    }

    private func bundleID(for url: URL) -> String? {
        if let cached = bundleIDsByURL[url] { return cached }
        let id = Bundle(url: url)?.bundleIdentifier
        if let id { bundleIDsByURL[url] = id }
        return id
    }

    /// Optimistically drops a window we just closed.
    func forget(_ item: WindowItem) {
        items.removeAll { $0.id == item.id }
    }

    // MARK: - AX thread

    private func bootstrap(_ infos: [AppInfo], frontmost: pid_t) {
        frontmostPID = frontmost
        axCurrentSpaces = Private.currentSpaces()
        for info in infos { addApp(info, isLaunch: false) }

        // Seed recency from the on-screen stacking order (front to back).
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let ids = onScreen.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        clock = UInt64(ids.count + 1)
        for (rank, id) in ids.enumerated() {
            windows[id]?.lastFocus = clock - UInt64(rank)
        }
        clock += 1
        if let app = apps[frontmost] {
            app.lastActivation = clock
            if let focused = Self.element(app.element, kAXFocusedWindowAttribute), let id = Private.windowID(of: focused) {
                windows[id]?.lastFocus = clock
            }
        }
        refreshBadges()
        publishNow()

        // Windows on other Spaces are invisible to the regular AX API; find them afterwards.
        thread.perform { [self] in discoverOffscreenWindows() }
    }

    private func addApp(_ info: AppInfo, isLaunch: Bool) {
        guard apps[info.pid] == nil else { return }
        let app = TrackedApp(info)
        apps[info.pid] = app
        register(app)
        if isLaunch {
            // Freshly launched apps create windows lazily; look again a few times.
            for delay in [0.5, 1.5, 4.0] {
                thread.perform(after: delay) { [weak self, weak app] in
                    guard let self, let app, self.apps[info.pid] === app else { return }
                    self.discoverWindows(of: app)
                    // Restored windows may live on other Spaces (e.g. full screen).
                    if delay == 4.0 { self.discoverOffscreenWindows(only: info.pid) }
                }
            }
            clock += 1
            app.lastActivation = clock
        }
        schedulePublish()
    }

    private func register(_ app: TrackedApp) {
        guard apps[app.info.pid] === app else { return }
        if app.observer == nil {
            var observer: AXObserver?
            guard AXObserverCreate(app.info.pid, axObserverCallback, &observer) == .success, let observer else {
                return retry(app)
            }
            app.observer = observer
            CFRunLoopAddSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        if !app.notificationsRegistered, let observer = app.observer {
            let ok = Self.appNotifications.allSatisfy { name in
                let err = AXObserverAddNotification(observer, app.element, name as CFString, nil)
                return err == .success || err == .notificationAlreadyRegistered || err == .notificationUnsupported
            }
            if ok { app.notificationsRegistered = true } else { retry(app) }
        }
        discoverWindows(of: app)
    }

    private func retry(_ app: TrackedApp) {
        app.attempts += 1
        guard app.attempts <= 10 else { return }
        let delay = min(0.1 * pow(2, Double(app.attempts)), 5)
        thread.perform(after: delay) { [weak self, weak app] in
            guard let self, let app else { return }
            self.register(app)
        }
    }

    private func removeApp(_ pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        if let observer = app.observer {
            CFRunLoopRemoveSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        for id in gone { windows.removeValue(forKey: id) }
        DispatchQueue.main.async {
            ThumbnailService.shared.evict(gone)
            IconCache.evict(pid: pid)
        }
        schedulePublish()
    }

    private func discoverWindows(of app: TrackedApp) {
        guard let list = Self.value(app.element, kAXWindowsAttribute) as? [AXUIElement] else { return }
        var changed = false
        for element in list where addWindow(element, app: app) { changed = true }
        if changed { schedulePublish() }
    }

    /// Validates and starts tracking a window. Returns true if it was new.
    @discardableResult
    private func addWindow(_ element: AXUIElement, app: TrackedApp) -> Bool {
        guard let id = Private.windowID(of: element), windows[id] == nil,
              let attributes = WindowAttributes(element), attributes.isSwitchable,
              Self.isNormalLevel(id), let observer = app.observer else { return false }
        // Without a destroy notification we'd never learn the window closed;
        // skip it for now, a later discovery pass will pick it up.
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
        let registered = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        guard registered == .success || registered == .notificationAlreadyRegistered else { return false }
        for name in Self.windowNotifications where name != kAXUIElementDestroyedNotification {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        windows[id] = TrackedWindow(id: id, pid: app.info.pid, element: element, attributes: attributes)
        return true
    }

    private func removeWindow(_ id: CGWindowID) {
        guard windows.removeValue(forKey: id) != nil else { return }
        DispatchQueue.main.async { ThumbnailService.shared.evict([id]) }
        schedulePublish()
    }

    private func bump(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        clock += 1
        window.lastFocus = clock
        apps[window.pid]?.lastActivation = clock
        schedulePublish()
    }

    private func appActivated(_ pid: pid_t, info: AppInfo?) {
        frontmostPID = pid
        refreshBadges()
        if apps[pid] == nil, let info { addApp(info, isLaunch: false) }
        guard let app = apps[pid] else { return }
        clock += 1
        app.lastActivation = clock
        if let focused = Self.element(app.element, kAXFocusedWindowAttribute), let id = Private.windowID(of: focused) {
            if windows[id] == nil { addWindow(focused, app: app) }
            windows[id]?.lastFocus = clock
        }
        schedulePublish()
    }

    private func setHidden(_ pid: pid_t, _ hidden: Bool) {
        guard let app = apps[pid], app.info.isHidden != hidden else { return }
        app.info.isHidden = hidden
        schedulePublish()
    }

    private func spaceChanged(rescan: Bool = true) {
        axCurrentSpaces = Private.currentSpaces()
        for window in windows.values { window.spaces = Private.spaces(for: window.id) }
        if rescan {
            // Windows on the newly visible Space are now reachable through AX.
            for app in apps.values { discoverWindows(of: app) }
        }
        schedulePublish()
    }

    fileprivate func handle(notification name: String, element: AXUIElement, refcon: UnsafeMutableRawPointer?) {
        let windowID = refcon.map { CGWindowID(truncatingIfNeeded: UInt(bitPattern: $0)) }
        switch name {
        case kAXUIElementDestroyedNotification:
            if let windowID { removeWindow(windowID) }

        case kAXTitleChangedNotification:
            guard let windowID, let window = windows[windowID] else { return }
            let title = Self.value(element, kAXTitleAttribute) as? String ?? window.title
            if title != window.title {
                window.title = title
                schedulePublish()
            }

        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard let windowID, let window = windows[windowID] else { return }
            window.isMinimized = name == kAXWindowMiniaturizedNotification
            schedulePublish()

        case kAXWindowResizedNotification:
            guard let windowID, let window = windows[windowID] else { return }
            let fullscreen = Self.value(element, "AXFullScreen") as? Bool ?? false
            if fullscreen != window.isFullscreen {
                window.isFullscreen = fullscreen
                window.spaces = Private.spaces(for: windowID)
                schedulePublish()
            }

        case kAXWindowCreatedNotification:
            guard let app = app(of: element) else { return }
            if addWindow(element, app: app) {
                schedulePublish()
            } else {
                // Some windows only get their subrole a moment after creation.
                thread.perform(after: 0.25) { [weak self, weak app] in
                    guard let self, let app, self.addWindow(element, app: app) else { return }
                    self.schedulePublish()
                }
            }

        case kAXFocusedWindowChangedNotification:
            guard let app = app(of: element), let id = Private.windowID(of: element) else { return }
            if windows[id] == nil, addWindow(element, app: app) { schedulePublish() }
            if app.info.pid == frontmostPID { bump(id) }

        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            guard let app = app(of: element) else { return }
            setHidden(app.info.pid, name == kAXApplicationHiddenNotification)

        default:
            break
        }
    }

    private func app(of element: AXUIElement) -> TrackedApp? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return apps[pid]
    }

    /// Finds windows living on other Spaces. The window server knows about
    /// them, but AX only lists windows on the current Space, so we enumerate
    /// the app's AX element ids until we find the matching window ids.
    private func discoverOffscreenWindows(only pid: pid_t? = nil) {
        guard Private.canCreateRemoteElements,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        var wanted: [pid_t: Set<CGWindowID>] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, windows[id] == nil,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, apps[owner] != nil,
                  pid == nil || pid == owner,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 50, bounds.height >= 50,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            wanted[owner, default: []].insert(id)
        }
        // One app per run loop turn so notifications keep flowing meanwhile.
        var queue = Array(wanted)
        func next() {
            guard let (pid, ids) = queue.popLast() else { return }
            if let app = apps[pid] { bruteForce(app, ids: ids) }
            thread.perform(next)
        }
        next()
    }

    private func bruteForce(_ app: TrackedApp, ids: Set<CGWindowID>) {
        // Skip apps that don't answer; every probe would wait for the timeout.
        guard Self.value(app.element, kAXRoleAttribute) != nil else { return }
        var token = Private.remoteToken(pid: app.info.pid)
        var remaining = ids
        var added = false
        for elementID in UInt64(0)..<1000 {
            guard let element = Private.remoteElement(pid: app.info.pid, elementID: elementID, token: &token),
                  let id = Private.windowID(of: element), remaining.remove(id) != nil else { continue }
            if addWindow(element, app: app) { added = true }
            if remaining.isEmpty { break }
        }
        if added { schedulePublish() }
    }

    // MARK: - Publishing

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        thread.perform { [self] in
            publishPending = false
            publishNow()
        }
    }

    private func publishNow() {
        var out: [WindowItem] = []
        out.reserveCapacity(windows.count + 8)
        var withWindows = Set<pid_t>()
        for window in windows.values {
            guard let app = apps[window.pid] else { continue }
            withWindows.insert(window.pid)
            let (title, profile) = BrowserTitle.split(window.title, appName: app.info.name, bundleID: app.info.bundleID)
            out.append(WindowItem(
                id: UInt64(window.id), windowID: window.id, pid: window.pid,
                element: window.element, appElement: app.element,
                title: title, profile: profile, appName: app.info.name, bundleID: app.info.bundleID,
                isMinimized: window.isMinimized, isAppHidden: app.info.isHidden,
                isFullscreen: window.isFullscreen, badge: badge(for: app.info),
                spaces: window.spaces, lastFocus: window.lastFocus
            ))
        }
        for app in apps.values where app.info.isRegular && !withWindows.contains(app.info.pid) {
            out.append(WindowItem(
                id: WindowItem.windowlessID(pid: app.info.pid), windowID: 0, pid: app.info.pid,
                element: nil, appElement: app.element,
                title: "", profile: nil, appName: app.info.name, bundleID: app.info.bundleID,
                isMinimized: false, isAppHidden: app.info.isHidden,
                isFullscreen: false, badge: badge(for: app.info), spaces: [], lastFocus: app.lastActivation
            ))
        }
        out.sort(by: Self.mruOrder)
        let spaces = axCurrentSpaces
        DispatchQueue.main.async { [self] in
            items = out
            currentSpaces = spaces
            onChange?()
        }
    }

    private func badge(for app: AppInfo) -> String? {
        app.bundleID.flatMap { badges[$0] } ?? badges["name:" + app.name]
    }

    static func mruOrder(_ a: WindowItem, _ b: WindowItem) -> Bool {
        if a.lastFocus != b.lastFocus { return a.lastFocus > b.lastFocus }
        if a.isWindowless != b.isWindowless { return !a.isWindowless }
        return a.id < b.id
    }

    // MARK: - AX helpers

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isNormalLevel(_ id: CGWindowID) -> Bool {
        var raw = UnsafeRawPointer(bitPattern: UInt(id))
        guard let array = CFArrayCreate(nil, &raw, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return true }
        return layer == 0
    }
}

/// The attributes we need to decide whether a window belongs in the switcher,
/// fetched in a single IPC round trip.
struct WindowAttributes {
    var role: String?
    var subrole: String?
    var title: String
    var isMinimized: Bool
    var isFullscreen: Bool
    var size: CGSize

    private static let names = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXSizeAttribute,
    ] as CFArray

    init?(_ element: AXUIElement) {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.names, [], &values) == .success,
              let array = values as? [AnyObject], array.count == 6 else { return nil }
        role = array[0] as? String
        subrole = array[1] as? String
        title = array[2] as? String ?? ""
        isMinimized = array[3] as? Bool ?? false
        isFullscreen = array[4] as? Bool ?? false
        var size = CGSize.zero
        if CFGetTypeID(array[5]) == AXValueGetTypeID() {
            AXValueGetValue(array[5] as! AXValue, .cgSize, &size)
        }
        self.size = size
    }

    var isSwitchable: Bool {
        role == kAXWindowRole
            && (subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole)
            && size.width >= 50 && size.height >= 50
    }
}
