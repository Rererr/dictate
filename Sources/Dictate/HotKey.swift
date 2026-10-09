import AppKit
import Carbon.HIToolbox
import DictateKit

/// 押下と解放を知らせるグローバルホットキー。
@MainActor
protocol HotkeyListener: AnyObject {
    func stop()
}

@MainActor
func makeHotkeyListener(_ hotkey: Config.Hotkey, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws -> any HotkeyListener {
    switch hotkey.trigger {
    case .key(let code): try KeyHotKey(hotkey, keyCode: code, onPress: onPress, onRelease: onRelease)
    case .mouse(let button): try MouseButtonTap(hotkey, button: button, onPress: onPress, onRelease: onRelease)
    }
}

/// キーと修飾キーの組み合わせ。RegisterEventHotKey は権限が要らず、登録した組み合わせしか届かない。
@MainActor
final class KeyHotKey: HotkeyListener {
    struct RegistrationError: Error, LocalizedError {
        let name: String
        let status: OSStatus

        var errorDescription: String? { "ホットキー \(name) を登録できません（OSStatus \(status)）。" }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(_ hotkey: Config.Hotkey, keyCode: UInt32, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        self.onPress = onPress
        self.onRelease = onRelease

        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let hotKey = Unmanaged<KeyHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if kind == UInt32(kEventHotKeyPressed) { hotKey.onPress() } else { hotKey.onRelease() }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { throw RegistrationError(name: hotkey.displayName, status: installed) }

        // 他のアプリが同じ組み合わせを登録していても、この呼び出しは成功する（排他オプションでも同じ。実測）。
        // 競合は登録時には分からない
        let registered = RegisterEventHotKey(
            keyCode, hotkey.carbonModifiers, EventHotKeyID(signature: 0x4443_5454, id: 1), GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registered == noErr else {
            stop()
            throw RegistrationError(name: hotkey.displayName, status: registered)
        }
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

/// マウスの中ボタンとサイドボタン。ホットキー登録では取れないので、イベントタップで受ける。
/// 受け取る種類はマウスボタンの押下と解放だけで、キー入力は通らない。
@MainActor
final class MouseButtonTap: HotkeyListener {
    struct PermissionError: Error, LocalizedError {
        var errorDescription: String? {
            "マウスボタンのホットキーには、アクセシビリティの許可が要ります。システム設定 > プライバシーとセキュリティ > アクセシビリティで、Dictate を許可してください。"
        }
    }

    private static let relevantFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let button: Int64
    private let flags: CGEventFlags
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var isDown = false

    init(_ hotkey: Config.Hotkey, button: Int, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        self.button = Int64(button)
        self.flags = hotkey.eventFlags
        self.onPress = onPress
        self.onRelease = onRelease

        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
        guard AXIsProcessTrusted(), let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<MouseButtonTap>.fromOpaque(context).takeUnretainedValue()
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                let flags = event.flags
                let swallow = MainActor.assumeIsolated { listener.handle(type, button: button, flags: flags) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw PermissionError() }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    /// 登録したボタンなら true を返し、前面アプリには渡さない
    /// （渡すと、サイドボタンでブラウザが前のページへ戻る）。
    private func handle(_ type: CGEventType, button: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // OS は応答の遅いタップを止める。止まったままだとホットキーが黙って効かなくなる
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard button == self.button else { return false }
        if type == .otherMouseDown {
            guard flags.intersection(Self.relevantFlags) == self.flags else { return false }
            isDown = true
            onPress()
            return true
        }
        // 修飾キーを先に離しても、押下を受けたボタンの解放は必ず受ける
        guard isDown else { return false }
        isDown = false
        onRelease()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

extension Config.Hotkey {
    var carbonModifiers: UInt32 {
        let flags: [Modifier: Int] = [.command: cmdKey, .shift: shiftKey, .option: optionKey, .control: controlKey]
        return UInt32(modifiers.reduce(0) { $0 | (flags[$1] ?? 0) })
    }

    var eventFlags: CGEventFlags {
        let flags: [Modifier: CGEventFlags] = [.command: .maskCommand, .shift: .maskShift, .option: .maskAlternate, .control: .maskControl]
        return modifiers.reduce(into: []) { $0.formUnion(flags[$1] ?? []) }
    }

    init(trigger: Trigger, flags: NSEvent.ModifierFlags) {
        let pairs: [(NSEvent.ModifierFlags, Modifier)] = [(.control, .control), (.option, .option), (.shift, .shift), (.command, .command)]
        self.init(trigger: trigger, modifiers: pairs.filter { flags.contains($0.0) }.map(\.1))
    }

    /// macOS 自体の有効なショートカットと同じ組み合わせか。調べられなければ nil。
    /// 他のアプリのホットキーは調べる手段が無い。
    var collidesWithSystemShortcut: Bool? {
        guard case .key(let code) = trigger else { return false }
        var copied: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&copied) == noErr, let entries = copied?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? UInt32) == code
                && (entry[kHISymbolicHotKeyModifiers as String] as? UInt32) == carbonModifiers
        }
    }
}
