import AppKit

NativeSwitcher.runWatchdogIfRequested()
_ = AXDump.runIfRequested()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if DemoSnapshot.runIfRequested() {
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
