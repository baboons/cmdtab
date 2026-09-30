import AppKit

/// Development aid: dumps what Accessibility exposes for a browser's windows.
/// Run via LaunchServices so CmdTab's own Accessibility grant applies:
///
///   open -n build/CmdTab.app --args --ax-dump /tmp/ax.txt [bundle-id]
enum AXDump {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ax-dump"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        let bundleID = i + 2 < args.count ? args[i + 2] : "com.google.Chrome"
        var text = "AX trusted: \(AXIsProcessTrusted())\n"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            text += "== \(app.localizedName ?? "?") pid \(app.processIdentifier)\n"
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 2)
            let windows = WindowStore.value(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if windows.isEmpty { walk(axApp, depth: 0, maxDepth: 4, budget: 200, into: &text) }
            for window in windows {
                text += "-- window title=\(describe(WindowStore.value(window, kAXTitleAttribute)))\n"
                walk(window, depth: 0, maxDepth: 9, budget: 400, into: &text)
            }
        }
        try? text.write(to: out, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, budget: Int, into text: inout String) {
        var remaining = budget
        func visit(_ el: AXUIElement, _ depth: Int) {
            guard remaining > 0, depth <= maxDepth else { return }
            remaining -= 1
            let role = WindowStore.value(el, kAXRoleAttribute) as? String ?? "?"
            let fields = [
                ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                ("help", kAXHelpAttribute), ("value", kAXValueAttribute), ("id", kAXIdentifierAttribute),
                ("status", "AXStatusLabel"), ("url", kAXURLAttribute),
            ].compactMap { name, attr -> String? in
                guard let raw = WindowStore.value(el, attr) else { return nil }
                let v = (raw as? String) ?? (raw as? URL)?.absoluteString ?? ""
                return v.isEmpty ? nil : "\(name)=\(v.prefix(80).debugDescription)"
            }
            // Only print the interesting bits: buttons/popups/groups with text.
            if !fields.isEmpty || depth < 3 {
                text += String(repeating: "  ", count: depth) + role + " " + fields.joined(separator: " ") + "\n"
            }
            let children = WindowStore.value(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children { visit(child, depth + 1) }
        }
        visit(element, depth)
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        return String(describing: value).debugDescription
    }
}
