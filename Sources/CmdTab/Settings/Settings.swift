import AppKit
import Combine
import ServiceManagement

enum TriggerModifier: String, CaseIterable, Identifiable {
    case command, option, control

    var id: String { rawValue }

    var flags: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        }
    }
}

/// What releasing the trigger modifier (⌘) does once the switcher is showing.
enum ReleaseBehavior: String, CaseIterable, Identifiable {
    /// Classic: switch to the selected window.
    case switchWindow
    /// Stay open so you can type to search; ↩ switches, esc cancels.
    case stayOpen
    var id: String { rawValue }
}

enum SwitcherStyle: String, CaseIterable, Identifiable {
    case previews, list
    var id: String { rawValue }
}

enum PreviewSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.25
        }
    }
}

/// A key plus modifiers, stored as a raw CGEventFlags mask.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers).intersection(Self.relevantFlags) }

    init(keyCode: UInt16, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(Self.relevantFlags).rawValue
    }

    var display: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + KeyCode.name(for: keyCode)
    }

    static let defaultSearch = KeyCombo(keyCode: KeyCode.tab, flags: [.maskCommand, .maskAlternate])
}

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var trigger: TriggerModifier { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var searchHotkey: KeyCombo? { didSet { saveSearchHotkey() } }
    /// Milliseconds to wait before showing the switcher in hold mode, so a
    /// quick ⌘Tab tap flips to the previous window without flashing the UI.
    @Published var appearDelay: Double { didSet { defaults.set(appearDelay, forKey: "appearDelay") } }
    @Published var releaseBehavior: ReleaseBehavior { didSet { defaults.set(releaseBehavior.rawValue, forKey: "releaseBehavior") } }
    @Published var style: SwitcherStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    @Published var previewSize: PreviewSize { didSet { defaults.set(previewSize.rawValue, forKey: "previewSize") } }
    @Published var showHints: Bool { didSet { defaults.set(showHints, forKey: "showHints") } }
    @Published var showBadges: Bool { didSet { defaults.set(showBadges, forKey: "showBadges") } }
    @Published var showClock: Bool { didSet { defaults.set(showClock, forKey: "showClock") } }
    @Published var showMinimized: Bool { didSet { defaults.set(showMinimized, forKey: "showMinimized") } }
    @Published var showHiddenApps: Bool { didSet { defaults.set(showHiddenApps, forKey: "showHiddenApps") } }
    @Published var showOtherSpaces: Bool { didSet { defaults.set(showOtherSpaces, forKey: "showOtherSpaces") } }
    @Published var showWindowlessApps: Bool { didSet { defaults.set(showWindowlessApps, forKey: "showWindowlessApps") } }
    @Published var learnFromSelections: Bool { didSet { defaults.set(learnFromSelections, forKey: "learnFromSelections") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var autoInstallUpdates: Bool { didSet { defaults.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("CmdTab: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "trigger": TriggerModifier.command.rawValue,
            "appearDelay": 90.0,
            "releaseBehavior": ReleaseBehavior.stayOpen.rawValue,
            "style": SwitcherStyle.previews.rawValue,
            "previewSize": PreviewSize.medium.rawValue,
            "showHints": true,
            "showBadges": true,
            "showClock": false,
            "showMinimized": true,
            "showHiddenApps": true,
            "showOtherSpaces": true,
            "showWindowlessApps": true,
            "learnFromSelections": true,
            "autoCheckUpdates": true,
            "autoInstallUpdates": true,
        ])
        trigger = TriggerModifier(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .command
        appearDelay = defaults.double(forKey: "appearDelay")
        releaseBehavior = ReleaseBehavior(rawValue: defaults.string(forKey: "releaseBehavior") ?? "") ?? .stayOpen
        style = SwitcherStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .previews
        previewSize = PreviewSize(rawValue: defaults.string(forKey: "previewSize") ?? "") ?? .medium
        showHints = defaults.bool(forKey: "showHints")
        showBadges = defaults.bool(forKey: "showBadges")
        showClock = defaults.bool(forKey: "showClock")
        showMinimized = defaults.bool(forKey: "showMinimized")
        showHiddenApps = defaults.bool(forKey: "showHiddenApps")
        showOtherSpaces = defaults.bool(forKey: "showOtherSpaces")
        showWindowlessApps = defaults.bool(forKey: "showWindowlessApps")
        learnFromSelections = defaults.bool(forKey: "learnFromSelections")
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        autoInstallUpdates = defaults.bool(forKey: "autoInstallUpdates")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if let data = defaults.data(forKey: "searchHotkey") {
            searchHotkey = try? JSONDecoder().decode(KeyCombo?.self, from: data)
        } else {
            searchHotkey = .defaultSearch
        }
    }

    private func saveSearchHotkey() {
        if let data = try? JSONEncoder().encode(searchHotkey) {
            defaults.set(data, forKey: "searchHotkey")
        }
    }

    static var learnFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CmdTab", isDirectory: true).appendingPathComponent("learned.tsv")
    }
}
