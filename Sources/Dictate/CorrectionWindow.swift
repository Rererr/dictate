import AppKit
import DictateKit

/// 直前の発話を直して、差分から辞書の行を足す窓（ADR-18）。
/// 候補は初期値で入れ、本人は違うところだけ直す。
@MainActor
final class CorrectionWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let window: NSWindow
    private let original: String
    private let historyTexts: [String]
    private let editor = NSTextView()
    private let proposalsStack = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "辞書に足す", target: nil, action: nil)
    private let onFinish: ([DictionaryFile.Row]?) -> Void
    /// 誤表記をキーに持つ。打鍵のたびに作り直すが、本人が直した欄とチェックは引き継ぐ
    private var rows: [(wrong: String, surface: String, check: NSButton, surfaceField: NSTextField, readingField: NSTextField, note: NSTextField)] = []
    /// 読みごとの集計。履歴が大きいと 1 回の走査に秒がかかるので、背景で数えて結果を取っておく
    private var usages: [String: ReadingUsage] = [:]
    /// 数え始めた読み（結果待ちを含む）。同じ読みを重ねて数えない
    private var requested: Set<String> = []
    /// 走査は直列に 1 本ずつ（Task.detached は取り消せないので、重ねずに待つ）
    private var counting: Task<Void, Never>?
    private var finished = false

    /// - Parameters:
    ///   - historyTexts: 履歴の挿入文。読みの出現を数えるのに使う（空なら「履歴なし」）。
    ///   - corrected: 開いた時点の文。通常は original と同じで、デモ再生では直した文を入れて提案の見た目を出す。
    init(original: String, corrected: String? = nil, historyTexts: [String], onFinish: @escaping ([DictionaryFile.Row]?) -> Void) {
        self.original = original
        // 直している発話自体も履歴に入っている。その出現は巻き込みでないので、最後の 1 件を数えない
        var texts = historyTexts
        if let index = texts.lastIndex(of: original) { texts.remove(at: index) }
        self.historyTexts = texts
        self.onFinish = onFinish
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "直前の発話を直して辞書に足す"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let instruction = NSTextField(wrappingLabelWithString: "認識が違った語を直してください（Return で辞書に足す）。直した区間ごとに辞書の行（表記と、誤表記の読み）を提案します。句読点と空白だけの違いは提案しません。")
        editor.string = corrected ?? original
        editor.font = .systemFont(ofSize: 16)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.delegate = self
        editor.setAccessibilityLabel("直前の発話")
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true

        proposalsStack.orientation = .vertical
        proposalsStack.alignment = .leading
        proposalsStack.spacing = 8
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        addButton.target = self
        addButton.action = #selector(add)
        addButton.bezelStyle = .push
        let buttons = NSStackView(views: [NSView(), cancelButton, addButton])
        buttons.orientation = .horizontal

        // 提案は上に詰め、窓の余白は空の view に吸わせる
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        proposalsStack.setContentHuggingPriority(.required, for: .vertical)
        let stack = NSStackView(views: [instruction, scroll, summary, proposalsStack, spacer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
                instruction.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                scroll.heightAnchor.constraint(equalToConstant: 90),
                summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                proposalsStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            ])
        }
        refresh()
    }

    func show() {
        window.center()
        bringToFront()
        window.makeFirstResponder(editor)
    }

    func bringToFront() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func textDidChange(_ notification: Notification) {
        refresh()
    }

    /// 入力欄の Return は改行でなく「辞書に足す」。発話は 1 行で、改行が表記に混ざると辞書の行が壊れる
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        add()
        return true
    }

    /// 直した文から提案を作り直す。表記と読みの欄は初期値で入れ、本人が直した値とチェックは引き継ぐ。
    private func refresh() {
        let proposals = DictionaryProposal.propose(original: original, corrected: editor.string)
        let previous = Dictionary(rows.map { ($0.wrong, $0) }, uniquingKeysWith: { first, _ in first })
        for view in proposalsStack.arrangedSubviews { proposalsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        rows = proposals.map { proposal in
            let kept = previous[proposal.wrong]
            let check = NSButton(checkboxWithTitle: "「\(proposal.wrong)」を", target: nil, action: nil)
            check.state = kept?.check.state ?? .on
            // 提案の表記が変わったときだけ入れ直す（本人が直した欄を、別の場所の打鍵で戻さない）
            let surface = NSTextField(string: kept.map { $0.surface == proposal.surface ? $0.surfaceField.stringValue : proposal.surface } ?? proposal.surface)
            surface.placeholderString = "表記"
            surface.setAccessibilityLabel("表記")
            surface.delegate = self
            let reading = NSTextField(string: kept?.readingField.stringValue ?? proposal.reading)
            reading.placeholderString = "読み"
            reading.setAccessibilityLabel("読み")
            reading.delegate = self
            let line = NSStackView(views: [check, surface, NSTextField(labelWithString: "読み"), reading])
            line.orientation = .horizontal
            let note = NSTextField(wrappingLabelWithString: "")
            note.font = .systemFont(ofSize: 11)
            let block = NSStackView(views: [line, note])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 2
            proposalsStack.addArrangedSubview(block)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalToConstant: 160),
                reading.widthAnchor.constraint(equalToConstant: 160),
                note.widthAnchor.constraint(equalTo: proposalsStack.widthAnchor),
            ])
            return (proposal.wrong, proposal.surface, check, surface, reading, note)
        }
        summary.textColor = .secondaryLabelColor
        summary.stringValue = proposals.isEmpty
            ? (editor.string == original ? "まだ直していません。" : "辞書の行になる差分がありません（句読点と空白、算用数字、語の追加と削除は対象外です）。")
            : "提案 \(proposals.count) 件。表記と読みは直せます。チェックした行を dictionary.tsv の末尾に足します。"
        addButton.isEnabled = !proposals.isEmpty
        updateNotes()
        countMissingReadings()
    }

    /// 表記か読みの欄が直されたら、注記を出し直し、新しい読みを数える
    func controlTextDidChange(_ notification: Notification) {
        updateNotes()
        countMissingReadings()
    }

    private var currentReadings: [String] {
        rows.map { $0.readingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// まだ数えていない読みを背景で数える。前の走査が終わってから始め、結果は捨てずに取っておく（走査は履歴の大きさに比例して数秒かかる）。
    private func countMissingReadings() {
        let missing = Set(currentReadings).subtracting(requested)
        guard !missing.isEmpty, !historyTexts.isEmpty else { return }
        requested.formUnion(missing)
        let texts = historyTexts
        let previous = counting
        counting = Task {
            await previous?.value
            let counted = await Task.detached { ReadingUsage.of(readings: Array(missing), in: texts) }.value
            guard !finished else { return }
            usages.merge(counted) { _, new in new }
            updateNotes()
        }
    }

    private func updateNotes() {
        for row in rows {
            let reading = row.readingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !historyTexts.isEmpty else {
                row.note.stringValue = "履歴がないので、この読みが普段どう書かれているかは分かりません。"
                row.note.textColor = .secondaryLabelColor
                continue
            }
            guard let usage = usages[reading] else {
                row.note.stringValue = "履歴でこの読みがどう書かれているかを数えています…"
                row.note.textColor = .secondaryLabelColor
                continue
            }
            let collides = usage.collides(with: row.surfaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            row.note.stringValue = Self.usageNote(usage, collides: collides)
            row.note.textColor = collides ? .systemOrange : .secondaryLabelColor
        }
    }

    /// 履歴でその読みがどう書かれているか。直した表記以外の語（誤表記を正しく使った箇所を含む）があれば、足すと巻き込むことを示す（ADR-10）。
    static func usageNote(_ usage: ReadingUsage, collides: Bool) -> String {
        guard usage.total > 0 else { return "履歴の挿入文に、この読みの語はありません。" }
        let breakdown = usage.surfaces.map { "\($0.surface)×\($0.count)" }.joined(separator: "、")
        return "履歴でこの読みは \(usage.total) 回（\(breakdown)）。" + (collides ? "この表記以外の語（誤表記を正しく使った箇所を含む）も、すべてこの表記に置き換わります。" : "")
    }

    @objc private func add() {
        guard addButton.isEnabled else { return }
        let selected = rows.compactMap { row -> DictionaryFile.Row? in
            guard row.check.state == .on else { return nil }
            return DictionaryFile.Row(
                surface: row.surfaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                reading: row.readingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !selected.isEmpty else {
            show(problem: "足す行がありません。チェックを付けてください。")
            return
        }
        if let empty = selected.first(where: { $0.surface.isEmpty || $0.reading.isEmpty }) {
            show(problem: "「\(empty.surface.isEmpty ? "表記" : "読み")」が空の行があります。埋めるか、チェックを外してください。")
            return
        }
        let problems = DictionaryFile.problems(in: selected)
        guard problems.isEmpty else {
            show(problem: problems.joined() + "直すか、チェックを外してください。")
            return
        }
        finish(selected)
    }

    /// 足せない理由を、足すボタンの上に出す（窓は閉じない）。
    private func show(problem: String) {
        summary.stringValue = problem
        summary.textColor = .systemOrange
    }

    @objc private func cancel() {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ result: [DictionaryFile.Row]?) {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        onFinish(result)
    }
}
