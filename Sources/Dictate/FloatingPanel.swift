import AppKit

/// 画面下に出す二つの窓。話している間の字幕と、挿入できなかった理由などを知らせるトースト。
/// 成功は知らせない（入力欄に文が入ること自体が合図になる）。
/// どちらもフォーカスを取らない（取ると挿入先のカーソルが外れる）。
@MainActor
final class Overlay {
    enum CaptionKind {
        case recording, working
    }

    private static let bottomMargin: CGFloat = 72
    private static let gap: CGFloat = 10
    private static let captionSize = NSSize(width: 620, height: 52)
    private static let toastMaxLabelWidth: CGFloat = 660

    private let caption = HUDWindow()
    private let toast = HUDWindow()
    private var toastGeneration = 0

    init() {
        // 字幕は末尾（いま話している箇所）を 1 行で見せる
        caption.label.maximumNumberOfLines = 1
        caption.label.lineBreakMode = .byTruncatingHead
        // トーストは理由の先頭が要るので、折り返して全文を出す
        toast.label.maximumNumberOfLines = 8
        toast.label.lineBreakMode = .byWordWrapping
        toast.label.cell?.wraps = true
        toast.label.preferredMaxLayoutWidth = Self.toastMaxLabelWidth
        toast.dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }

    func showCaption(_ kind: CaptionKind, _ text: String) {
        caption.dot.layer?.backgroundColor = (kind == .recording ? NSColor.systemRed : NSColor.systemBlue).cgColor
        caption.label.stringValue = text
        guard !caption.panel.isVisible, let screen = NSScreen.main?.visibleFrame else { return }
        caption.panel.setFrame(NSRect(
            x: screen.midX - Self.captionSize.width / 2, y: screen.minY + Self.bottomMargin,
            width: Self.captionSize.width, height: Self.captionSize.height
        ), display: true)
        caption.panel.orderFrontRegardless()
        // 前の発話の理由を読み切る前に話し始めても、字幕で隠さない
        if toast.panel.isVisible { placeToast() }
    }

    func closeCaption() {
        caption.panel.orderOut(nil)
    }

    /// 理由を見せてから閉じる。長い文言は読む時間を足す。
    /// 句点ごとに改行し、起きたことと次にすることを行で分ける。
    func showToast(_ text: String) {
        toast.label.stringValue = text.replacingOccurrences(of: "。", with: "。\n").trimmingCharacters(in: .whitespacesAndNewlines)
        placeToast()
        toast.panel.orderFrontRegardless()
        toastGeneration += 1
        let generation = toastGeneration
        Task {
            try? await Task.sleep(for: .seconds(1.7 + Double(text.count) * 0.06))
            if generation == toastGeneration { toast.panel.orderOut(nil) }
        }
    }

    private func placeToast() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let text = toast.label.sizeThatFits(NSSize(width: Self.toastMaxLabelWidth, height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(text.width) + HUDWindow.horizontalChrome, height: max(44, ceil(text.height) + 26))
        let lift = caption.panel.isVisible ? Self.captionSize.height + Self.gap : 0
        toast.panel.setFrame(NSRect(
            x: screen.midX - size.width / 2, y: screen.minY + Self.bottomMargin + lift, width: size.width, height: size.height
        ), display: true)
    }
}

/// 暗い半透明の地に、状態を示す丸と文言を並べた窓。
@MainActor
private final class HUDWindow {
    static let horizontalChrome: CGFloat = 18 + 10 + 12 + 18

    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    let dot = NSView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .vibrantDark)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }
}
