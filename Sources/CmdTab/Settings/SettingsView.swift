import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @StateObject private var permissions = PermissionState()
    var onRecordingShortcut: (Bool) -> Void
    var onForgetLearning: () -> Void
    @StateObject private var local = LocalState()

    // `@State` is a macro in recent SDKs whose plugin ships only with Xcode;
    // plain ObservableObjects keep this buildable with the Command Line Tools.
    final class LocalState: ObservableObject {
        @Published var forgot = false
    }

    var body: some View {
        Form {
            Section {
                Picker("Switch windows with", selection: $settings.trigger) {
                    ForEach(TriggerModifier.allCases) { Text("\($0.symbol) Tab").tag($0) }
                }
                Picker("Releasing \(settings.trigger.symbol)", selection: $settings.releaseBehavior) {
                    Text("Stays open to search (Tab + release switches)").tag(ReleaseBehavior.stayOpen)
                    Text("Always switches (classic)").tag(ReleaseBehavior.switchWindow)
                }
                LabeledContent("Search windows with") {
                    ShortcutRecorder(combo: $settings.searchHotkey, onRecording: onRecordingShortcut)
                }
                LabeledContent("Appear after") {
                    HStack {
                        Slider(value: $settings.appearDelay, in: 0...300, step: 10)
                            .frame(width: 170)
                        Text("\(Int(settings.appearDelay)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text(settings.releaseBehavior == .stayOpen
                     ? "Press \(settings.trigger.symbol)Tab and type to filter; ↩ switches, esc cancels. Tab to a window and release \(settings.trigger.symbol) to switch right away. A quick tap jumps back to your previous window."
                     : "Hold \(settings.trigger.symbol) and press Tab to cycle. Keep holding and type to filter; release to switch. A quick tap jumps back to your previous window.")
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Toggle("Learn from my choices", isOn: $settings.learnFromSelections)
                LabeledContent("Learned shortcuts") {
                    Button(local.forgot ? "Forgotten" : "Forget…") {
                        onForgetLearning()
                        local.forgot = true
                    }
                    .disabled(local.forgot)
                }
            }

            Section("Appearance") {
                Picker("Style", selection: $settings.style) {
                    Text("Previews").tag(SwitcherStyle.previews)
                    Text("List").tag(SwitcherStyle.list)
                }
                .pickerStyle(.segmented)
                if settings.style == .previews {
                    Picker("Preview size", selection: $settings.previewSize) {
                        Text("Small").tag(PreviewSize.small)
                        Text("Medium").tag(PreviewSize.medium)
                        Text("Large").tag(PreviewSize.large)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Show notification badges", isOn: $settings.showBadges)
                Toggle("Show keyboard hints", isOn: $settings.showHints)
            }

            Section("Windows") {
                Toggle("Minimized windows", isOn: $settings.showMinimized)
                Toggle("Hidden apps", isOn: $settings.showHiddenApps)
                Toggle("Windows on other Spaces", isOn: $settings.showOtherSpaces)
                Toggle("Apps without windows", isOn: $settings.showWindowlessApps)
            }

            Section("Permissions") {
                PermissionRow(title: "Accessibility", detail: "Required to see windows and replace ⌘Tab.",
                              granted: permissions.accessibility) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "Screen Recording", detail: "Optional. Shows live window previews.",
                              granted: permissions.screenRecording, action: Permissions.requestScreenRecording)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $settings.autoCheckUpdates)
                Toggle("Install updates automatically", isOn: $settings.autoInstallUpdates)
                    .disabled(!settings.autoCheckUpdates)
                LabeledContent("Version") {
                    HStack {
                        Text("\(Bundle.main.shortVersion) · core \(SearchEngine.coreVersion)")
                            .foregroundStyle(.secondary)
                        Button("Check Now") { Updater.shared.check(userInitiated: true) }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates are installed while you're not using the switcher; CmdTab restarts in about a second.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
        .onAppear { permissions.startPolling(whileGranted: {}) }
        .onDisappear { permissions.stopPolling() }
    }
}

/// Click, then press a key combination (with ⌘, ⌥ or ⌃). Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var onRecording: (Bool) -> Void
    @StateObject private var state = RecorderState()

    final class RecorderState: ObservableObject {
        @Published var recording = false
        var monitor: Any?
    }

    private var recording: Bool { state.recording }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…" : (combo?.display ?? "Not set"))
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
            }
            if combo != nil, !recording {
                Button(action: { combo = nil }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        state.recording = true
        onRecording(true)
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyCode.escape {
                stop()
                return nil
            }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
            guard !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else {
                NSSound.beep()
                return nil
            }
            combo = KeyCombo(keyCode: event.keyCode, flags: flags)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
        state.monitor = nil
        if state.recording { onRecording(false) }
        state.recording = false
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
