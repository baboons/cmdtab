import AppKit
import ApplicationServices

enum WindowAction {
    case close, minimize, toggleFullscreen, hideApp, quitApp
}

/// Operations on windows. AX calls can block on unresponsive apps, so they
/// run on a serial background queue, never on the main thread.
enum WindowActions {
    private static let queue = DispatchQueue(label: "CmdTab.actions", qos: .userInteractive)

    static func focus(_ item: WindowItem) {
        queue.async {
            if item.isAppHidden {
                AXUIElementSetAttributeValue(item.appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            }
            guard let window = item.element else {
                if !Private.focus(pid: item.pid, window: 0) {
                    DispatchQueue.main.async { NSRunningApplication(processIdentifier: item.pid)?.activate() }
                }
                return
            }
            if item.isMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let focused = Private.focus(pid: item.pid, window: item.windowID)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if !focused {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.async { NSRunningApplication(processIdentifier: item.pid)?.activate() }
            }
        }
    }

    static func perform(_ action: WindowAction, on item: WindowItem) {
        switch action {
        case .quitApp:
            NSRunningApplication(processIdentifier: item.pid)?.terminate()
        case .hideApp:
            NSRunningApplication(processIdentifier: item.pid)?.hide()
        case .close:
            guard let window = item.element else { return }
            queue.async {
                if let button = WindowStore.element(window, kAXCloseButtonAttribute) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            }
        case .minimize:
            guard let window = item.element else { return }
            queue.async {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, (!item.isMinimized) as CFBoolean)
            }
        case .toggleFullscreen:
            guard let window = item.element else { return }
            queue.async {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!item.isFullscreen) as CFBoolean)
            }
        }
    }
}
