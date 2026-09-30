import AppKit

/// An entry in the switcher: a window, or an app without windows.
/// Immutable snapshot handed from the Accessibility thread to the UI.
struct WindowItem {
    let id: UInt64
    /// 0 for window-less apps.
    let windowID: CGWindowID
    let pid: pid_t
    let element: AXUIElement?
    let appElement: AXUIElement
    /// Window title, minus a browser's " - Google Chrome – Profile" suffix.
    let title: String
    /// Browser profile the window belongs to (Chromium browsers with several profiles).
    let profile: String?
    let appName: String
    let bundleID: String?
    let isMinimized: Bool
    let isAppHidden: Bool
    let isFullscreen: Bool
    /// The app's Dock badge ("3", "•"), if any.
    let badge: String?
    let spaces: [UInt64]
    var lastFocus: UInt64

    var isWindowless: Bool { windowID == 0 }

    /// Key used by the learning store: selections are remembered per app
    /// (and per browser profile, so "work" and "personal" learn separately).
    var learnKey: String {
        let base = bundleID ?? appName
        return profile.map { "\(base)|\($0)" } ?? base
    }

    /// The title as shown and searched: "Profile · Page title" for browser profiles.
    var searchTitle: String {
        guard let profile else { return title }
        return title.isEmpty ? profile : "\(profile)\(Self.profileSeparator)\(title)"
    }

    /// UTF-16 length of the profile prefix in `searchTitle` (for styling).
    var profilePrefixLength: Int {
        guard let profile else { return 0 }
        return (profile as NSString).length + (title.isEmpty ? 0 : (Self.profileSeparator as NSString).length)
    }

    static let profileSeparator = "  ·  "

    static func windowlessID(pid: pid_t) -> UInt64 {
        (1 << 32) | UInt64(UInt32(bitPattern: pid))
    }
}

/// Chromium browsers title windows "Page - Google Chrome – Profile" (the
/// profile part only when several profiles exist). Splits that apart.
enum BrowserTitle {
    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium.", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.", "com.operasoftware.",
    ]

    static func split(_ raw: String, appName: String, bundleID: String?) -> (title: String, profile: String?) {
        guard let bundleID, chromiumBundlePrefixes.contains(where: bundleID.hasPrefix),
              let marker = raw.range(of: " - \(appName)", options: .backwards) else { return (raw, nil) }
        let page = String(raw[..<marker.lowerBound])
        let rest = raw[marker.upperBound...]
        if rest.isEmpty { return (page, nil) }
        for separator in [" – ", " - "] where rest.hasPrefix(separator) {
            let profile = rest.dropFirst(separator.count).trimmingCharacters(in: .whitespaces)
            return (page, profile.isEmpty ? nil : profile)
        }
        return (raw, nil)
    }
}

/// App metadata captured on the main thread (NSRunningApplication is main-thread friendly).
struct AppInfo {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let isRegular: Bool
    var isHidden: Bool

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
        bundleID = app.bundleIdentifier
        isRegular = app.activationPolicy == .regular
        isHidden = app.isHidden
    }
}
