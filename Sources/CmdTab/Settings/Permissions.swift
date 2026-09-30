import AppKit
import ApplicationServices
import SwiftUI

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Polls permission state while the onboarding window is visible.
final class PermissionState: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    private var timer: Timer?

    /// `whileGranted` runs on every tick while Accessibility is granted, so a
    /// start that failed right after the grant is retried.
    func startPolling(whileGranted: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = Permissions.accessibility
            if granted { whileGranted() }
            self.accessibility = granted
            self.screenRecording = Permissions.screenRecording
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var state: PermissionState
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to CmdTab").font(.title2.weight(.semibold))
                    Text("A faster ⌘Tab with every window and instant search.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required to see windows and replace ⌘Tab.",
                    granted: state.accessibility,
                    action: {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Optional. Shows live window previews.",
                    granted: state.screenRecording,
                    action: Permissions.requestScreenRecording
                )
            }

            HStack {
                if !state.screenRecording && state.accessibility {
                    Text("Granted screen recording? Relaunch to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Relaunch", action: Permissions.relaunch).controlSize(.small)
                }
                Spacer()
                Button(state.accessibility ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 460)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.snappy, value: granted)
    }
}
