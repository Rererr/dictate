import AppKit
import DictateKit

/// ホットキーを登録する窓。窓の上で押したキーの組み合わせかマウスボタンを捕まえる。
/// 自分の窓への入力なので、捕まえるのに権限は要らない。
@MainActor
final class HotkeyRecorder: NSObject, NSWindowDelegate {
    private static let hint = "他のアプリのホットキーは検出できません。保存した後に一度押して、他のアプリが反応しないか確かめてください。"

    private let window: NSWindow
    private let display = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let saveDisabledReason: String?
    private let onFinish: (Config.Hotkey?) -> Void
    private var monitor: Any?
    private var captured: Config.Hotkey?
    private var finished = false

    /// - Parameter saveDisabledReason: 保存できない理由（デモ再生中など）。nil なら保存できる。
    init(current: Config.Hotkey, saveDisabledReason: String?, onFinish: @escaping (Config.Hotkey?) -> Void) {
        self.saveDisabledReason = saveDisabledReason
        self.onFinish = onFinish
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "ホットキーを登録"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let instruction = NSTextField(wrappingLabelWithString: "この窓の上で、登録したいキーの組み合わせか、マウスの中ボタンかサイドボタンを押してください。押している間だけ録音します。")
        display.font = .systemFont(ofSize: 30, weight: .semibold)
        display.alignment = .center
        display.stringValue = "現在: \(current.displayName)"
        display.setAccessibilityLabel("登録するホットキー")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.stringValue = Self.hint

        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [instruction, display, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.widthAnchor.constraint(equalToConstant: 460),
                display.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            ])
        }
    }

    func show() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 捕まえたら true（窓の通常の処理には渡さない）。
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.type == .otherMouseDown {
            capture(Config.Hotkey(trigger: .mouse(button: event.buttonNumber), flags: flags))
            return true
        }
        // 修飾キーなしの Esc、Return、Tab は窓の操作に残す（キーボードだけで保存とキャンセルができるように）
        if flags.isEmpty, [53, 36, 48].contains(event.keyCode) {
            if event.keyCode == 53 { cancel() }
            return event.keyCode == 53
        }
        capture(Config.Hotkey(trigger: .key(code: UInt32(event.keyCode)), flags: flags))
        return true
    }

    private func capture(_ hotkey: Config.Hotkey) {
        captured = hotkey
        display.stringValue = hotkey.displayName
        if let problem = hotkey.problem {
            show(note: problem.localizedDescription, warning: true)
            saveButton.isEnabled = false
            return
        }
        saveButton.isEnabled = saveDisabledReason == nil
        if let saveDisabledReason {
            show(note: saveDisabledReason, warning: true)
            return
        }
        switch hotkey.collidesWithSystemShortcut {
        case true?:
            show(note: "macOS のショートカットと同じ組み合わせです。押すたびに macOS 側の動作も起きる可能性があります。システム設定 > キーボード > キーボードショートカットで確認できます。", warning: true)
        case false?:
            show(note: Self.hint, warning: false)
        case nil:
            show(note: "macOS のショートカットとの重なりを確認できませんでした。\(Self.hint)", warning: true)
        }
    }

    private func show(note text: String, warning: Bool) {
        note.stringValue = text
        note.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    @objc private func save() {
        guard let captured, captured.problem == nil, saveDisabledReason == nil else { return }
        finish(captured)
    }

    @objc private func cancel() {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ result: Config.Hotkey?) {
        guard !finished else { return }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        window.orderOut(nil)
        onFinish(result)
    }
}
