import AppKit

/// Development aid: renders the real switcher panel with sample windows and
/// writes a PNG, without needing any permissions.
///
///   CmdTab --demo-snapshot out.png [--query "sl"] [--list] [--dark|--light] [--select N]
@MainActor
enum DemoSnapshot {
    private static var panel: SwitcherPanel?

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-snapshot"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let query = value("--query") ?? ""
        let style: SwitcherStyle = args.contains("--list") ? .list : .previews
        let select = value("--select").flatMap(Int.init)
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        DispatchQueue.main.async { render(to: out, query: query, style: style, select: select) }
        return true
    }

    private static let samples: [(app: String, path: String, title: String, profile: String?, tint: UInt32)] = [
        ("Google Chrome", "/Applications/Google Chrome.app", "Pull request #42 · baboons/cmdtab", "Work", 0x2F7CF6),
        ("Terminal", "/System/Applications/Utilities/Terminal.app", "~/Projects/cmdtab — cargo test", nil, 0x2B2B2B),
        ("Google Chrome", "/Applications/Google Chrome.app", "Google Meet", "Personal", 0x1E8E3E),
        ("Mail", "/System/Applications/Mail.app", "Inbox — 3 unread", nil, 0x3A8DDE),
        ("Notes", "/System/Applications/Notes.app", "Release checklist", nil, 0xF2C94C),
        ("Music", "/System/Applications/Music.app", "Listen Now", nil, 0xFA3C5A),
        ("Finder", "/System/Library/CoreServices/Finder.app", "Downloads", nil, 0x5AA9F8),
        ("Calendar", "/System/Applications/Calendar.app", "September 2026", nil, 0xE8453C),
        ("System Settings", "/System/Applications/System Settings.app", "Accessibility", nil, 0x8E8E93),
        ("Slack", "/Applications/Slack.app", "general — Baboons", nil, 0x611F69),
    ]

    private static func render(to out: URL, query: String, style: SwitcherStyle, select: Int?) {
        let appElement = AXUIElementCreateApplication(getpid())
        var items: [WindowItem] = []
        for (i, s) in samples.enumerated() {
            let item = WindowItem(
                id: UInt64(90_000 + i), windowID: CGWindowID(90_000 + i), pid: getpid(), element: nil, appElement: appElement,
                title: s.title, profile: s.profile, appName: s.app, bundleID: "demo.\(s.app)", isMinimized: i == 6, isAppHidden: false,
                isFullscreen: false, badge: ["Mail": "3", "Slack": "12", "Calendar": "•"][s.app],
                spaces: [], lastFocus: UInt64(100 - i)
            )
            items.append(item)
            IconCache.setOverride(NSWorkspace.shared.icon(forFile: s.path), for: item.id)
            ThumbnailService.shared.inject(mockThumbnail(title: s.title, tint: s.tint, seed: i), for: item.windowID)
        }

        let engine = SearchEngine(learnFile: nil)
        engine.setItems(items)
        let results = engine.search(query)

        let screen = NSScreen.main!.visibleFrame
        let layout = SwitcherLayout.make(style: style, scale: 1, itemCount: items.count, screen: screen, hints: true)
        let panel = SwitcherPanel()
        self.panel = panel
        let height = layout.height(for: results.count)
        panel.setFrame(CGRect(x: screen.midX - layout.width / 2, y: screen.midY - height / 2, width: layout.width, height: height), display: false)
        panel.switcherView.begin(layout: layout, mode: query.isEmpty ? .hold : .sticky, trigger: .command, releaseSwitches: false)
        panel.switcherView.update(query: query, results: results, selected: select ?? (query.isEmpty ? 1 : 0), animated: false)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var written: [String] = []
            if let image = Private.captureWindow(CGWindowID(panel.windowNumber), bestResolution: true) {
                write(image, to: out)
                written.append(out.path)
            }
            let view = panel.contentView!
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let alt = out.deletingPathExtension().appendingPathExtension("view.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: alt)
                written.append(alt.path)
            }
            print("demo-snapshot: \(results.count) results for \"\(query)\" -> \(written.joined(separator: ", "))")
            exit(0)
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A plausible-looking window: title bar, sidebar and content blocks.
    private static func mockThumbnail(title: String, tint: UInt32, seed: Int) -> CGImage {
        let size = CGSize(width: 1200, height: 760)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        let dark = seed % 3 == 1
        ctx.setFillColor(rgb(dark ? 0x1E1E22 : 0xFAFAFC))
        ctx.fill(CGRect(origin: .zero, size: size))
        // Title bar
        ctx.setFillColor(rgb(dark ? 0x2A2A30 : 0xECECF0))
        ctx.fill(CGRect(x: 0, y: size.height - 64, width: size.width, height: 64))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(UInt32(c)))
            ctx.fillEllipse(in: CGRect(x: 24 + CGFloat(i) * 30, y: size.height - 42, width: 20, height: 20))
        }
        // Sidebar
        ctx.setFillColor(rgb(tint, dark ? 0.25 : 0.12))
        ctx.fill(CGRect(x: 0, y: 0, width: 260, height: size.height - 64))
        for row in 0..<8 {
            ctx.setFillColor(rgb(dark ? 0xFFFFFF : 0x000000, 0.12))
            ctx.fill(CGRect(x: 28, y: size.height - 120 - CGFloat(row) * 54, width: CGFloat(140 + (row * 37 + seed * 11) % 70), height: 18))
        }
        // Hero block + text lines
        ctx.setFillColor(rgb(tint, 0.85))
        ctx.fill(CGRect(x: 300, y: size.height - 330, width: size.width - 340, height: 230))
        for row in 0..<7 {
            ctx.setFillColor(rgb(dark ? 0xFFFFFF : 0x000000, row == 0 ? 0.5 : 0.14))
            let w = CGFloat(420 + (row * 131 + seed * 53) % 420)
            ctx.fill(CGRect(x: 300, y: size.height - 390 - CGFloat(row) * 44, width: w, height: row == 0 ? 26 : 16))
        }
        return ctx.makeImage()!
    }
}
