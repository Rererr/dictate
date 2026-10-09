import AppKit
import ApplicationServices
import DictateKit

/// 前面アプリのカーソル位置に文字列を入れる。AX を先に試し、入らなければ貼り付ける。
@MainActor
struct Inserter {
    struct Result {
        let insertion: UtteranceRecord.Insertion
        /// 貼り付けの後始末（クリップボードの復元）。終わるまで次の挿入を始めない。
        let cleanup: Task<Void, Never>?
    }

    // AX の反映が遅れるアプリで「変わっていない」と誤判定すると二重挿入になる。実測で調整する
    private static let axSettleDelay = Duration.milliseconds(50)
    // 貼り付けが届く前に戻すと、戻した後の内容が貼られる。実測で調整する
    private static let pasteSettleDelay = Duration.milliseconds(300)

    func insert(_ text: String, forcePaste: Bool) async -> Result {
        guard AXIsProcessTrusted() else {
            return Result(insertion: .init(method: .none, reason: Messages.accessibilityDenied), cleanup: nil)
        }
        if forcePaste { return paste(text, reason: "設定で常に貼り付けるアプリ") }

        var focusedValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusError == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return paste(text, reason: "フォーカス中の入力欄を取得できない（AXError \(focusError.rawValue)）")
        }
        let element = focusedValue as! AXUIElement  // 直前で型 ID を確かめている

        let before = snapshot(element)
        let setError = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard setError == .success else {
            return paste(text, reason: "AX の書き込みが失敗（AXError \(setError.rawValue)）")
        }
        try? await Task.sleep(for: Self.axSettleDelay)
        let after = snapshot(element)

        // 読めないものを「入っていない」と決めると、入っていた場合に同じ文が二度入る
        guard let before, let after else {
            return Result(insertion: .init(method: .ax, reason: Messages.unverified), cleanup: nil)
        }
        if before == after {
            return paste(text, reason: "AX は成功を返したが入力欄が変わらない")
        }
        return Result(insertion: .init(method: .ax, reason: nil), cleanup: nil)
    }

    /// Shift つきは、チャットの入力欄で送信せずに改行する。
    func pressReturn(shift: Bool) {
        post(keyCode: 36, flags: shift ? .maskShift : [])
    }

    private struct Snapshot: Equatable {
        let selection: CFRange
        let value: String

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.selection.location == b.selection.location && a.selection.length == b.selection.length && a.value == b.value
        }
    }

    /// 選択範囲と内容の両方が読めたときだけ返す。
    private func snapshot(_ element: AXUIElement) -> Snapshot? {
        var rangeValue: CFTypeRef?
        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(), let text = textValue as? String
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }  // 直前で型 ID を確かめている
        return Snapshot(selection: range, value: text)
    }

    private func paste(_ text: String, reason: String) -> Result {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // クリップボード履歴アプリが拾わないための印（nspasteboard.org の約束事）
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pasteboard.changeCount
        post(keyCode: 9, flags: .maskCommand)

        let cleanup = Task { @MainActor in
            try? await Task.sleep(for: Self.pasteSettleDelay)
            // 本人がその間に別のものをコピーしていたら戻さない
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        return Result(insertion: .init(method: .paste, reason: reason), cleanup: cleanup)
    }

    /// 修飾キーを明示する。ホットキーの修飾キーがまだ押されていても混ざらない。
    private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
