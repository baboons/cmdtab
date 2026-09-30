import AppKit

/// Turns the system ⌘Tab switcher off while CmdTab owns ⌘Tab, and makes very
/// sure it comes back when we quit, crash or get killed.
enum NativeSwitcher {
    private static var disabled = false

    static func setEnabled(_ enabled: Bool) {
        for key in Private.SymbolicHotKey.allCases {
            Private.setSymbolicHotKey(key, enabled: enabled)
        }
        disabled = !enabled
    }

    static func restore() {
        if disabled { setEnabled(true) }
    }

    /// SIGKILL (Force Quit, `kill -9`) can't be caught, so a tiny child
    /// process waits for us to exit and turns the system switcher back on.
    static func spawnWatchdog() {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [watchdogFlag, String(getpid())]
        try? process.run()
    }

    static let watchdogFlag = "--watchdog"

    /// Entry point of the watchdog process.
    static func runWatchdogIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: watchdogFlag), i + 1 < args.count, let parent = pid_t(args[i + 1]) else { return }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            restoreFromSignal()
            exit(0)
        }
        source.resume()
        if kill(parent, 0) != 0 { // already gone
            restoreFromSignal()
            exit(0)
        }
        withExtendedLifetime(source) { dispatchMain() }
    }

    /// Restores the system switcher on abnormal termination too.
    static func installSafetyNet() {
        atexit { NativeSwitcher.restoreFromSignal() }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { sig in
                NativeSwitcher.restoreFromSignal()
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    /// Best effort from a signal handler: one call per symbolic hotkey.
    private static func restoreFromSignal() {
        for key in Private.SymbolicHotKey.allCases {
            Private.setSymbolicHotKey(key, enabled: true)
        }
    }
}
