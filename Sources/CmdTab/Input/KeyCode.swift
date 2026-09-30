import AppKit
import Carbon.HIToolbox

enum KeyCode {
    static let tab = UInt16(kVK_Tab)
    static let returnKey = UInt16(kVK_Return)
    static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
    static let escape = UInt16(kVK_Escape)
    static let delete = UInt16(kVK_Delete)
    static let forwardDelete = UInt16(kVK_ForwardDelete)
    static let space = UInt16(kVK_Space)
    static let left = UInt16(kVK_LeftArrow)
    static let right = UInt16(kVK_RightArrow)
    static let up = UInt16(kVK_UpArrow)
    static let down = UInt16(kVK_DownArrow)
    static let home = UInt16(kVK_Home)
    static let end = UInt16(kVK_End)
    static let pageUp = UInt16(kVK_PageUp)
    static let pageDown = UInt16(kVK_PageDown)

    static func name(for code: UInt16) -> String {
        switch Int(code) {
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return KeyTranslator.shared.character(for: code, shift: false)?.uppercased() ?? "#\(code)"
        }
    }
}

/// Maps virtual key codes to characters using the user's current keyboard
/// layout, ignoring modifiers. Typing "å" on a Swedish layout while holding ⌘
/// therefore searches for "å", not whatever ⌘/⌥ would produce.
final class KeyTranslator {
    static let shared = KeyTranslator()

    private var layoutData: Data?
    private var cache: [UInt32: String] = [:]

    private init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    private func reload() {
        cache.removeAll()
        layoutData = nil
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            return
        }
    }

    func character(for keyCode: UInt16, shift: Bool) -> String? {
        let cacheKey = UInt32(keyCode) | (shift ? 0x10000 : 0)
        if let hit = cache[cacheKey] { return hit.isEmpty ? nil : hit }
        guard let data = layoutData else { return nil }
        let result: String = data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return "" }
            return String(utf16CodeUnits: chars, count: length)
        }
        let printable = result.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? result : ""
        cache[cacheKey] = printable
        return printable.isEmpty ? nil : printable
    }
}
