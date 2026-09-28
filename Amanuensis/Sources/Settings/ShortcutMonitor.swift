import AppKit
import Carbon
import Combine

/// Actions that can be triggered by keyboard shortcuts
enum ShortcutAction: Hashable {
    case visionOCR   // Apple Vision offline text extraction
    case latex       // AI extraction with the LaTeX prompt
    case markdown    // AI extraction with the Markdown prompt
}

@MainActor
final class ShortcutMonitor: ObservableObject {
    static let shared = ShortcutMonitor()

    private var textHotKeyRef: EventHotKeyRef?
    private var latexHotKeyRef: EventHotKeyRef?
    private var markdownHotKeyRef: EventHotKeyRef?
    private var textHotKeyID = EventHotKeyID(signature: 0x4C544558, // 'LTEX'
                                            id: 1)
    private var latexHotKeyID = EventHotKeyID(signature: 0x4C544558,
                                             id: 2)
    private var markdownHotKeyID = EventHotKeyID(signature: 0x4C544558,
                                             id: 3)
    private var callback: ((ShortcutAction) -> Void)?
    private var textShortcut: KeyboardShortcut?
    private var latexShortcut: KeyboardShortcut?
    private var markdownShortcut: KeyboardShortcut?

    struct KeyboardShortcut: Codable, Sendable, Equatable {
        let keyCode: Int
        let modifiersRawValue: UInt

        static let supportedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

        var modifiers: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.supportedModifiers)
        }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if modifiers.contains(.command) { result |= UInt32(cmdKey) }
            if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
            if modifiers.contains(.option) { result |= UInt32(optionKey) }
            if modifiers.contains(.control) { result |= UInt32(controlKey) }
            return result
        }

        var description: String {
            var result = ""
            if modifiers.contains(.control) { result += "⌃" }
            if modifiers.contains(.option) { result += "⌥" }
            if modifiers.contains(.shift) { result += "⇧" }
            if modifiers.contains(.command) { result += "⌘" }
            return result + (Self.specialKeys[keyCode]?.label ?? keyEquivalentCharacter.uppercased())
        }

        var keyEquivalentCharacter: String {
            if let special = Self.specialKeys[keyCode] { return special.character }
            return Self.character(for: keyCode)
        }

        // Resolve physical keys using the current layout, including Å, Æ and Ø.
        static func character(for keyCode: Int, inputSource: TISInputSource? = nil) -> String {
            guard (0...127).contains(keyCode) else { return "" }
            let source = inputSource ?? TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return "" }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKey, buffer.count, &length, &buffer)
            guard status == noErr else { return "" }
            return String(utf16CodeUnits: buffer, count: length).lowercased()
        }

        static let specialKeys: [Int: (label: String, character: String)] = {
            var keys: [Int: (String, String)] = [
                kVK_Return: ("↩", "\r"), kVK_Tab: ("⇥", "\t"), kVK_Space: ("Space", " "),
                kVK_Delete: ("⌫", "\u{8}"), kVK_ForwardDelete: ("⌦", "\u{F728}"),
                kVK_Escape: ("⎋", "\u{1B}"),
                kVK_LeftArrow: ("←", "\u{F702}"), kVK_RightArrow: ("→", "\u{F703}"),
                kVK_UpArrow: ("↑", "\u{F700}"), kVK_DownArrow: ("↓", "\u{F701}"),
                kVK_Home: ("↖", "\u{F729}"), kVK_End: ("↘", "\u{F72B}"),
                kVK_PageUp: ("⇞", "\u{F72C}"), kVK_PageDown: ("⇟", "\u{F72D}"),
                kVK_ANSI_KeypadEnter: ("⌤", "\u{3}")
            ]
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                                kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
                                kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            for (index, code) in functionKeys.enumerated() {
                keys[code] = ("F\(index + 1)", String(UnicodeScalar(0xF704 + index)!))
            }
            return keys
        }()

        var validationError: String? {
            guard (0...127).contains(keyCode), !keyEquivalentCharacter.isEmpty else {
                return "This key cannot be used as a shortcut."
            }
            let isFunctionKey = Self.specialKeys[keyCode]?.label.hasPrefix("F") == true
            if modifiers.isEmpty && !isFunctionKey {
                return "Shortcuts require at least one modifier key."
            }
            return nil
        }

        init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            modifiersRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let code = try container.decode(Int.self, forKey: .keyCode)
            guard (0...127).contains(code) else {
                throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container, debugDescription: "Invalid key code")
            }
            self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: try container.decode(UInt.self, forKey: .modifiersRawValue)))
        }
    }

    @Published private(set) var registrationErrors: [ShortcutAction: String] = [:]
    private var isMonitoring = false
    private var isSuspended = false

    private init() {
        installEventHandler()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(GetApplicationEventTarget(),
                          { (nextHandler, theEvent, userData) -> OSStatus in
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userData!).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(theEvent,
                                         EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID),
                                         nil,
                                         MemoryLayout<EventHotKeyID>.size,
                                         nil,
                                         &hotKeyID)

            guard status == noErr else { return status }
            guard hotKeyID.signature == 0x4C544558 else { return OSStatus(eventNotHandledErr) }

            Task { @MainActor in
                guard monitor.isMonitoring, !monitor.isSuspended else { return }
                switch hotKeyID.id {
                case 1: monitor.callback?(.visionOCR)
                case 2: monitor.callback?(.latex)
                case 3: monitor.callback?(.markdown)
                default: break
                }
            }

            return noErr
        },
        1,
        &eventType,
        selfPtr,
        nil)
    }

    func startMonitoring(callback: @escaping (ShortcutAction) -> Void) {
        self.callback = callback
        isMonitoring = true
        registerHotKeys()
    }

    private func unregisterHotKeys() {
        if let ref = textHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = latexHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = markdownHotKeyRef { UnregisterEventHotKey(ref) }
        textHotKeyRef = nil
        latexHotKeyRef = nil
        markdownHotKeyRef = nil
    }

    func stopMonitoring() {
        isMonitoring = false
        unregisterHotKeys()
    }

    func suspendForRecording(_ suspended: Bool) {
        isSuspended = suspended
        registerHotKeys()
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        registrationErrors = [:]
        guard isMonitoring, !isSuspended else { return }
        func register(_ shortcut: KeyboardShortcut?, action: ShortcutAction, id: EventHotKeyID) -> EventHotKeyRef? {
            guard let shortcut else { return nil }
            if let error = shortcut.validationError {
                registrationErrors[action] = error
                return nil
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                            id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                registrationErrors[action] = "Could not register this shortcut. It may be used by macOS or another app (\(status))."
            }
            return ref
        }
        textHotKeyRef = register(textShortcut, action: .visionOCR, id: textHotKeyID)
        latexHotKeyRef = register(latexShortcut, action: .latex, id: latexHotKeyID)
        markdownHotKeyRef = register(markdownShortcut, action: .markdown, id: markdownHotKeyID)
    }

    func setShortcut(_ shortcut: KeyboardShortcut?, for action: ShortcutAction) {
        switch action {
        case .visionOCR: textShortcut = shortcut
        case .latex: latexShortcut = shortcut
        case .markdown: markdownShortcut = shortcut
        }
        registerHotKeys()
    }
}
