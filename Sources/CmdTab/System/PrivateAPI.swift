import AppKit
import ApplicationServices

typealias CGSConnectionID = Int32

/// Bindings to the private SkyLight / HIServices calls a real window switcher
/// needs (focusing a specific window across Spaces, capturing windows,
/// disabling the system ⌘Tab). Symbols are resolved lazily at runtime, so if a
/// future macOS removes one we degrade instead of failing to launch.
enum Private {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func symbol<T>(_ names: String..., as _: T.Type) -> T? {
        for name in names {
            if let handle = skyLight, let ptr = dlsym(handle, name) { return unsafeBitCast(ptr, to: T.self) }
            if let ptr = dlsym(defaultHandle, name) { return unsafeBitCast(ptr, to: T.self) }
        }
        return nil
    }

    // MARK: - Function types

    private typealias MainConnectionIDFn = @convention(c) () -> CGSConnectionID
    private typealias SetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias HWCaptureWindowListFn = @convention(c) (CGSConnectionID, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let mainConnectionIDFn = symbol("SLSMainConnectionID", "CGSMainConnectionID", as: MainConnectionIDFn.self)
    private static let setSymbolicHotKeyEnabledFn = symbol("SLSSetSymbolicHotKeyEnabled", "CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyEnabledFn.self)
    private static let setFrontProcessFn = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecordToFn = symbol("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let hwCaptureWindowListFn = symbol("SLSHWCaptureWindowList", "CGSHWCaptureWindowList", as: HWCaptureWindowListFn.self)
    private static let copySpacesForWindowsFn = symbol("SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let copyManagedDisplaySpacesFn = symbol("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let axGetWindowFn = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let axCreateWithRemoteTokenFn = symbol("_AXUIElementCreateWithRemoteToken", as: AXCreateWithRemoteTokenFn.self)
    private static let getProcessForPIDFn = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)

    static let connection: CGSConnectionID = mainConnectionIDFn?() ?? 0

    // MARK: - Symbolic hotkeys (system ⌘Tab)

    enum SymbolicHotKey: Int32, CaseIterable {
        case commandTab = 1
        case commandShiftTab = 2
    }

    static func setSymbolicHotKey(_ key: SymbolicHotKey, enabled: Bool) {
        _ = setSymbolicHotKeyEnabledFn?(key.rawValue, enabled)
    }

    // MARK: - Windows

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }

    static var canCreateRemoteElements: Bool { axCreateWithRemoteTokenFn != nil }

    /// Builds an AX element for `pid` from a raw element id. This is how we
    /// reach windows on other Spaces, which the regular AX API does not list.
    static func remoteElement(pid: pid_t, elementID: UInt64, token: inout Data) -> AXUIElement? {
        guard let fn = axCreateWithRemoteTokenFn else { return nil }
        withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
        return fn(token as CFData)?.takeRetainedValue()
    }

    static func remoteToken(pid: pid_t) -> Data {
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0)) { token.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: Int32(0x636F_636F)) { token.replaceSubrange(8..<12, with: $0) }
        return token
    }

    static var canQuerySpaces: Bool { copySpacesForWindowsFn != nil }

    /// Spaces a window lives on.
    static func spaces(for window: CGWindowID) -> [UInt64] {
        guard let fn = copySpacesForWindowsFn else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        guard let result = fn(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map(\.uint64Value)
    }

    /// The Space currently shown on each display.
    static func currentSpaces() -> Set<UInt64> {
        guard let fn = copyManagedDisplaySpacesFn,
              let displays = fn(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out = Set<UInt64>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = (current["ManagedSpaceID"] ?? current["id64"]) as? NSNumber {
                out.insert(id.uint64Value)
            }
        }
        return out
    }

    // MARK: - Capture

    static var canCaptureWindows: Bool { hwCaptureWindowListFn != nil }

    /// Captures a window's backing store, even when covered or on another Space.
    static func captureWindow(_ id: CGWindowID) -> CGImage? {
        guard let fn = hwCaptureWindowListFn else { return nil }
        var wid = id
        let ignoreGlobalClipShape: UInt32 = 1 << 11
        let nominalResolution: UInt32 = 1 << 9
        guard let images = fn(connection, &wid, 1, ignoreGlobalClipShape | nominalResolution)?.takeRetainedValue() as? [CGImage] else {
            return nil
        }
        return images.first
    }

    // MARK: - Focus

    /// Brings `window` of process `pid` to the front and makes it key, switching
    /// Spaces if needed. Returns false if the private path is unavailable.
    @discardableResult
    static func focus(pid: pid_t, window: CGWindowID) -> Bool {
        guard let getPSN = getProcessForPIDFn, let setFront = setFrontProcessFn else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFront(&psn, window, userGenerated) == 0 else { return false }
        if window != 0 { makeKey(psn: &psn, window: window) }
        return true
    }

    /// Synthesizes the two event records the WindowServer sends when a window
    /// is clicked, which makes it the key window of its app.
    /// Ported from https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    private static func makeKey(psn: inout ProcessSerialNumber, window: CGWindowID) {
        guard let post = postEventRecordToFn else { return }
        var wid = window
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x08] = kind
            bytes[0x3A] = 0x10
            withUnsafeBytes(of: &wid) { src in
                for i in 0..<4 { bytes[0x3C + i] = src[i] }
            }
            for i in 0x20..<0x30 { bytes[i] = 0xFF }
            bytes.withUnsafeMutableBufferPointer { _ = post(&psn, $0.baseAddress!) }
        }
    }
}
