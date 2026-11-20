import AppKit
import ApplicationServices
import DictateKit

/// 前面アプリのカーソル位置に文字列を入れる。AX を先に試し、入らなければ貼り付ける。
@MainActor
struct Inserter {
    struct Result {
        let insertion: UtteranceRecord.Insertion
        /// 貼り付けの後始末（入力欄が変わるのを待ってクリップボードを復元）。終わるまで次の挿入を始めない。
        /// 値は、貼り付けの後に入力欄が変わったか（読めなければ nil）と、その確認にかかった秒数。
        let cleanup: Task<(confirmed: Bool?, seconds: Double, detail: String?), Never>?
    }

    // AX の反映が遅れるアプリで「変わっていない」と誤判定すると二重挿入になる。Chrome は AX の書き込みを別プロセス（レンダラ）で
    // 非同期に適用するので、50 ms 固定の判定では間に合わないことがある。変わるまで 50 ms おきに最長 0.5 秒待つ（2026-10-20）
    private static let axVerifyTimeout = Duration.milliseconds(500)
    // 入力欄を読めないアプリでは、この時間だけ待ってから戻す（貼り付けが届く前に戻すと、戻した後の内容が貼られる）
    private static let pasteSettleDelay = Duration.milliseconds(300)
    // 入力欄が変わるのを待つ上限と間隔。Chrome で数回に一度入らない事象の切り分け（2026-10-20）
    private static let pasteVerifyTimeout = Duration.seconds(1)
    private static let pasteVerifyInterval = Duration.milliseconds(50)

    func insert(_ text: String, forcePaste: Bool) async -> Result {
        guard AXIsProcessTrusted() else {
            return Result(insertion: .init(method: .none, reason: Messages.accessibilityDenied), cleanup: nil)
        }
        var focusedValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue)
        let focused: AXUIElement? = focusError == .success && focusedValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
            ? (focusedValue as! AXUIElement) : nil  // 直前で型 ID を確かめている
        // 常に貼り付けるアプリでも、入力欄が読めるなら貼り付けの確認には使う
        if forcePaste { return paste(text, reason: "設定で常に貼り付けるアプリ", into: focused) }
        guard let element = focused else {
            return paste(text, reason: "フォーカス中の入力欄を取得できない（AXError \(focusError.rawValue)）", into: nil)
        }

        let before = snapshot(element)
        let setError = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard setError == .success else {
            return paste(text, reason: "AX の書き込みが失敗（AXError \(setError.rawValue)）", into: element)
        }
        let started = ContinuousClock.now
        var after = snapshot(element)
        // 読めないものを「入っていない」と決めると、入っていた場合に同じ文が二度入る
        guard let before, after != nil else {
            return Result(insertion: .init(method: .ax, reason: Messages.unverified), cleanup: nil)
        }
        while after == before, ContinuousClock.now - started < Self.axVerifyTimeout {
            try? await Task.sleep(for: Self.pasteVerifyInterval)
            after = snapshot(element)
        }
        if after == before {
            return paste(text, reason: "AX は成功を返したが入力欄が \(Int(Self.axVerifyTimeout.seconds * 1000)) ms たっても変わらない", into: element)
        }
        let waited = Int((ContinuousClock.now - started).seconds * 1000)
        return Result(insertion: .init(method: .ax, reason: nil, pasteConfirmed: nil, detail: "AX で \(waited) ms で確認"), cleanup: nil)
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

    /// element は貼り付け先の入力欄（読めるときだけ）。貼り付けの後に内容が変わるのを待ってからクリップボードを戻す。
    private func paste(_ text: String, reason: String, into element: AXUIElement?) -> Result {
        let pasteboard = NSPasteboard.general
        let before = element.flatMap(snapshot)
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
            let started = ContinuousClock.now
            var confirmed: Bool?
            if let element, let before {
                // 入力欄が変わるまで待つ。変わった時点でアプリはクリップボードを読み終えているので、すぐ戻してよい
                confirmed = false
                while ContinuousClock.now - started < Self.pasteVerifyTimeout {
                    try? await Task.sleep(for: Self.pasteVerifyInterval)
                    if let after = snapshot(element), after != before {
                        confirmed = true
                        break
                    }
                }
            } else {
                try? await Task.sleep(for: Self.pasteSettleDelay)
            }
            let seconds = (ContinuousClock.now - started).seconds
            var detail: String?
            if confirmed == false, let element {
                // 届かなかった回の手がかり: その時点の前面アプリ、フォーカス要素が同じか、その窓の題名、クリップボードが差し替えられていないか
                var focusedValue: CFTypeRef?
                AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue)
                let sameFocus = focusedValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } ?? false
                var windowValue: CFTypeRef?
                var titleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue)
                if let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                    AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
                }
                detail = "前面=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") 同じ要素=\(sameFocus) 窓=\((titleValue as? String ?? "?").prefix(30)) 自分が前面=\(NSApp.isActive) クリップボード=\(pasteboard.changeCount == ours ? "自分の" : "差し替わった")"
            }
            // 本人がその間に別のものをコピーしていたら戻さない
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { types in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
            }
            return (confirmed: confirmed, seconds: seconds, detail: detail)
        }
        return Result(insertion: .init(method: .paste, reason: reason), cleanup: cleanup)
    }

    /// 修飾キーを明示する。ホットキーの修飾キーがまだ押されていても混ざらない。
    /// 前面アプリのプロセスに直接送る。システム全体の入力経路（HID タップ）に流すと、他のイベントタップ（マウスのメーカー製ソフト等）を通り、
    /// Chrome で数回に一度 ⌘V が届かなかった（2026-10-20、貼り付け後 1 秒たっても入力欄が変わらない記録で確認）。前面アプリが取れなければ従来どおり流す
    private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            if let pid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
