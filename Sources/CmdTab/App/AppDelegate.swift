import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tap = KeyboardTap()
    private var controller: SwitcherController?
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let onboardingState = PermissionState()
    private var settingsObserver: AnyCancellable?
    private var paused = false
    /// Whether the tap can actually see ⌘Tab right now. If not (secure input,
    /// revoked permission, tap disabled), the system switcher takes over.
    private var tapHealthy = false
    private var healthTimer: Timer?
    private var pauseItem: NSMenuItem?
    private var searchItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeSwitcher.installSafetyNet()
        NativeSwitcher.spawnWatchdog()
        setupStatusItem()
        if Permissions.accessibility {
            start()
            if !Permissions.screenRecording && !UserDefaults.standard.bool(forKey: "askedScreenRecording") {
                UserDefaults.standard.set(true, forKey: "askedScreenRecording")
                showOnboarding()
            }
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeSwitcher.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Engine

    private func start() {
        guard controller == nil else { return }
        guard tap.start() else {
            if onboardingWindow?.isVisible != true { showOnboarding() }
            return
        }
        tapHealthy = true
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        WindowStore.shared.start()
        controller = SwitcherController(tap: tap)
        applySettings()
        settingsObserver = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        Updater.shared.canRelaunchNow = { [weak self] in
            guard let controller = self?.controller else { return true }
            return !controller.isOpen && Date().timeIntervalSince(controller.lastUsed) > 90
        }
        Updater.shared.onChange = { [weak self] in self?.refreshUpdateItem() }
        Updater.shared.start()
        // Warm the preview cache so the first ⌘Tab already has thumbnails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let ids = WindowStore.shared.items.filter { !$0.isWindowless }.map(\.windowID)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            ThumbnailService.shared.refresh(ids, maxPixels: CGSize(width: 290 * scale, height: 180 * scale))
        }
    }

    private func checkHealth() {
        tapHealthy = tap.isEnabled && AXIsProcessTrusted() && !IsSecureEventInputEnabled()
        applyNativeSwitcher()
    }

    /// The system switcher is on unless CmdTab owns ⌘Tab and can see it.
    /// Re-asserted on every health tick, so nothing else can leave it wrong.
    private func applyNativeSwitcher() {
        NativeSwitcher.setEnabled(paused || Settings.shared.trigger != .command || !tapHealthy)
    }

    private func applySettings() {
        let settings = Settings.shared
        tap.update(.init(trigger: settings.trigger.flags, searchCombo: settings.searchHotkey,
                         stayOpenOnRelease: settings.releaseBehavior == .stayOpen,
                         appearDelay: settings.appearDelay / 1000))
        tap.setEnabled(!paused)
        applyNativeSwitcher()
        searchItem?.title = settings.searchHotkey.map { "Search Windows  \($0.display)" } ?? "Search Windows"
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "CmdTab")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let search = NSMenuItem(title: "Search Windows", action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        searchItem = search
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        updateItem = update

        let pause = NSMenuItem(title: "Pause CmdTab", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func refreshUpdateItem() {
        switch Updater.shared.state {
        case let .ready(release, _): updateItem?.title = "Restart to Update to \(release.version)"
        case let .downloading(version): updateItem?.title = "Downloading \(version)…"
        case .checking: updateItem?.title = "Checking for Updates…"
        case .idle: updateItem?.title = "Check for Updates…"
        }
    }

    @objc private func checkForUpdates() {
        if case .ready = Updater.shared.state {
            Updater.shared.install()
        } else {
            Updater.shared.check(userInitiated: true)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem?.state = paused ? .on : .off
        searchItem?.isEnabled = !paused && controller != nil
        applySettings()
    }

    @objc private func openSearch() {
        // Let the menu finish closing first.
        DispatchQueue.main.async { self.controller?.openSticky() }
    }

    @objc private func togglePause() {
        paused.toggle()
        applySettings()
    }

    // MARK: - Windows

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                onRecordingShortcut: { [weak self] recording in
                    guard let self else { return }
                    self.tap.setEnabled(!recording && !self.paused)
                },
                onForgetLearning: { [weak self] in self?.controller?.clearLearning() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "CmdTab Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(state: onboardingState) { [weak self] in
                self?.onboardingWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "CmdTab"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        onboardingState.startPolling { [weak self] in
            guard let self, self.controller == nil else { return }
            self.start()
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
