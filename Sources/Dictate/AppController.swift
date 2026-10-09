import AppKit
@preconcurrency import AVFoundation
import Carbon.HIToolbox
import DictateKit
import SpeechCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private struct Recording {
        let startedAt: Date
        let started: ContinuousClock.Instant
        let session: Task<TranscriptAccumulator, Error>
    }

    private enum State {
        case idle
        case recording(Recording)
        /// 確定、後処理、挿入の間。
        case busy
    }

    private let demo: Bool
    private let clock = ContinuousClock()
    private let overlay = Overlay()
    private let microphone = MicrophoneCapture()
    private let inserter = Inserter()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var state = State.idle
    private var config = Config()
    private var dictionary = YomiDictionary(entries: [])
    private var hotKey: (any HotkeyListener)?
    private var recorder: HotkeyRecorder?
    /// これより短く離した押下は誤操作として、何も出さずに捨てる。
    private static let minimumHold = Duration.milliseconds(300)
    private var loadError: String?
    private var formatterReachable: Bool?
    private var lastUtterance: String?

    init(demo: Bool) {
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictate")
        reload()
        guard !demo else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        }
        // 文字列は kAXTrustedCheckOptionPrompt の値。定数は並行性検査を通らない
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - 設定

    @objc private func reload() {
        hotKey?.stop()
        hotKey = nil
        loadError = nil
        formatterReachable = nil
        do {
            config = try Config.load(from: AppPaths.config)
            dictionary = FileManager.default.fileExists(atPath: AppPaths.dictionary.path)
                ? try YomiDictionary(tsv: String(contentsOf: AppPaths.dictionary, encoding: .utf8))
                : YomiDictionary(entries: [])
            if !demo {
                hotKey = try makeHotkeyListener(config.hotkey, onPress: { [weak self] in self?.pressed() }, onRelease: { [weak self] in self?.released() })
            }
        } catch {
            // 壊れた設定を既定値に読み替えない。ホットキーを外したまま理由を出す
            loadError = error.localizedDescription
            overlay.showToast(Messages.loadFailed(error.localizedDescription))
        }
        rebuildMenu()
        guard loadError == nil, config.formatter.enabled else { return }
        let client = LLMClient(config.formatter)
        Task {
            formatterReachable = await client.isReachable()
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        if let loadError {
            info("設定エラーのため停止中: \(loadError)")
        } else if demo {
            info("デモ再生（マイクと認識は使いません）")
        } else {
            info("ホットキー: \(config.hotkey.displayName) を押している間")
            let reachability = switch formatterReachable {
            case .some(true): "接続可"
            case .some(false): "接続不可。整形前の文を挿入します"
            case .none: "接続を確認中"
            }
            info(config.formatter.enabled ? "整形: 有効（\(reachability)）" : "整形: 無効")
            info("履歴: \(config.history.enabled ? "有効" : "無効")")
            info("辞書: \(dictionary.isEmpty ? "なし" : "読み込み済み")")
        }
        menu.addItem(.separator())
        if demo {
            for (index, scenario) in DemoScenario.all.enumerated() {
                action(scenario.title, #selector(playDemo(_:))).tag = index
            }
            menu.addItem(.separator())
        }
        if loadError == nil, !demo {
            action("発話の後に改行する", #selector(toggleNewlineAfterUtterance)).state = config.newlineAfterUtterance ? .on : .off
            action("LLM で整える（フィラーと句読点）", #selector(toggleFormatter)).state = config.formatter.enabled ? .on : .off
        }
        _ = action("ホットキーを登録…", #selector(registerHotkey))
        _ = action("設定ファイルを開く", #selector(openConfigFile))
        _ = action("設定と辞書を再読み込み", #selector(reload))
        _ = action(lastUtterance == nil ? "直前の発話をコピー（まだありません）" : "直前の発話をコピー", #selector(copyLastUtterance), enabled: lastUtterance != nil)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func registerHotkey() {
        guard recorder == nil else { return }
        // 窓の上で今のホットキーを押したときに、録音が始まらないようにする
        hotKey?.stop()
        hotKey = nil
        let recorder = HotkeyRecorder(current: config.hotkey, saveDisabledReason: demo ? "デモ再生中は保存しません。" : nil) { [weak self] hotkey in
            guard let self else { return }
            self.recorder = nil
            if let hotkey {
                do {
                    try Config.update(at: AppPaths.config) { $0.hotkey = hotkey }
                } catch {
                    self.overlay.showToast(Messages.loadFailed(error.localizedDescription))
                }
            }
            self.reload()
        }
        self.recorder = recorder
        recorder.show()
    }

    @objc private func toggleNewlineAfterUtterance() {
        updateConfig { $0.newlineAfterUtterance.toggle() }
    }

    @objc private func toggleFormatter() {
        updateConfig { $0.formatter.enabled.toggle() }
    }

    private func updateConfig(_ change: (inout Config) -> Void) {
        do {
            try Config.update(at: AppPaths.config, change)
        } catch {
            overlay.showToast(Messages.loadFailed(error.localizedDescription))
        }
        reload()
    }

    /// 全項目を現在の値で書き出してから開く。壊れているときは、直せるようにそのまま開く。
    @objc private func openConfigFile() {
        if loadError == nil { try? Config.update(at: AppPaths.config) }
        guard FileManager.default.fileExists(atPath: AppPaths.config.path) else {
            overlay.showToast(Messages.loadFailed("設定ファイルを作れませんでした。"))
            return
        }
        NSWorkspace.shared.open(AppPaths.config)
    }

    @objc private func copyLastUtterance() {
        guard let lastUtterance else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastUtterance, forType: .string)
    }

    @objc private func playDemo(_ sender: NSMenuItem) {
        let scenario = DemoScenario.all[sender.tag]
        Task {
            for step in scenario.steps {
                try? await Task.sleep(for: step.after)
                switch step.action {
                case .caption(let kind, let text): overlay.showCaption(kind, text)
                case .closeCaption: overlay.closeCaption()
                case .toast(let text): overlay.showToast(text)
                }
            }
        }
    }

    // MARK: - 録音

    private func pressed() {
        switch state {
        case .recording:
            return  // 押し続けている間の繰り返し
        case .busy:
            overlay.showToast(Messages.busy)
            return
        case .idle:
            break
        }
        guard !IsSecureEventInputEnabled() else {
            overlay.showToast(Messages.secureInput)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            overlay.showToast(Messages.microphoneDenied)
            openPrivacySettings("Privacy_Microphone")
            return
        }
        let audio: AsyncStream<AudioChunk>
        do {
            audio = try microphone.start()
        } catch {
            overlay.showToast(Messages.microphoneFailed(error.localizedDescription))
            return
        }
        overlay.showCaption(.recording, Messages.listening)
        let transcriber = LiveTranscriber()
        let session = Task { [weak self] in
            var accumulator = TranscriptAccumulator()
            do {
                for try await event in try await transcriber.start(input: audio) {
                    accumulator.apply(event)
                    self?.showLive(accumulator.text)
                }
            } catch {
                self?.abortRecording(error)
                throw error
            }
            return accumulator
        }
        state = .recording(Recording(startedAt: Date(), started: clock.now, session: session))
    }

    /// 話している最中に認識が失敗したら、離すのを待たずに理由を出して待機に戻す。
    private func abortRecording(_ error: Error) {
        guard case .recording = state else { return }
        microphone.stop()
        state = .idle
        fail(Messages.recognitionFailed(error.localizedDescription))
    }

    private func showLive(_ text: String) {
        // キーを離した後に届く分で「確定中」の表示を上書きしない
        if case .recording = state { overlay.showCaption(.recording, text) }
    }

    private func released() {
        guard case .recording(let recording) = state else { return }
        microphone.stop()
        let released = clock.now
        guard released - recording.started >= Self.minimumHold else {
            recording.session.cancel()
            overlay.closeCaption()
            state = .idle
            return
        }
        state = .busy
        overlay.showCaption(.working, Messages.finalizing)
        Task {
            await finish(recording, released: released)
            state = .idle
        }
    }

    private func finish(_ recording: Recording, released: ContinuousClock.Instant) async {
        let accumulator: TranscriptAccumulator
        do {
            accumulator = try await recording.session.value
        } catch SpeechCoreError.noAudio {
            fail(Messages.noResult)
            return
        } catch {
            fail(Messages.recognitionFailed(error.localizedDescription))
            return
        }
        let finalized = clock.now
        let raw = accumulator.finalText
        let post = postprocess(raw, dictionary: dictionary)
        guard !post.afterDictionary.isEmpty else {
            fail(Messages.noResult)
            return
        }

        let id = UUID().uuidString
        var text = post.body
        var formatNote: String?
        if config.formatter.enabled, !post.body.isEmpty {
            overlay.showCaption(.working, Messages.formatting)
            let client = LLMClient(config.formatter)
            let body = post.body
            let formatting = Task.detached { await formatVerified(body, using: client.format) }
            let inBudget = await outcome(of: formatting, within: config.formatter.budgetSeconds)
            if let inBudget, inBudget.status == .adopted, let output = inBudget.output {
                text = output
            } else {
                formatNote = Messages.formatSkipped(inBudget?.status ?? .timedOut)
            }
            // 予算を超えた結果も、挿入済みの発話に後から足す
            Task {
                let result = await formatting.value
                record(FormatRecord(utteranceId: id, result: inBudget == nil ? result.afterBudget() : result))
            }
        }
        let postprocessed = clock.now

        // 話している間にパスワード欄へフォーカスが移った場合
        guard !IsSecureEventInputEnabled() else {
            lastUtterance = text.isEmpty ? lastUtterance : text
            rebuildMenu()
            fail(Messages.secureInputAtInsert)
            return
        }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var insertion = UtteranceRecord.Insertion(method: .none, reason: nil)
        var cleanup: Task<Void, Never>?
        if !text.isEmpty {
            let result = await inserter.insert(text, forcePaste: app.map(config.alwaysPasteBundleIds.contains) ?? false)
            insertion = result.insertion
            cleanup = result.cleanup
        }
        let inserted = clock.now
        await cleanup?.value

        // 本文が入らなかった、または入ったと確かめられなかったときは Return を送らない。
        // 入っていない欄に Return だけ届くと、元からあった下書きが送信される
        let confirmed = insertion.method == .paste || (insertion.method == .ax && insertion.reason == nil)
        // 設定で、挿入のたびに改行する。「送信して」があればそちらを優先する
        let command = post.command ?? (config.newlineAfterUtterance && !text.isEmpty ? .newline : nil)
        let sends = command != nil && (text.isEmpty ? AXIsProcessTrusted() : confirmed)
        if sends { inserter.pressReturn(shift: command == .newline) }

        overlay.closeCaption()
        lastUtterance = text.isEmpty ? lastUtterance : text
        rebuildMenu()
        let recorded = record(UtteranceRecord(
            id: id, startedAt: recording.startedAt, recordingSeconds: (released - recording.started).seconds,
            raw: raw, runs: accumulator.runs, post: post, inserted: insertion.method == .none ? "" : text,
            insertion: insertion, app: app,
            timings: .init(
                releaseToFinal: (finalized - released).seconds,
                postprocess: (postprocessed - finalized).seconds,
                insert: (inserted - postprocessed).seconds
            )
        ))
        guard recorded else { return }

        // 成功は知らせない。入力欄に文が入ること自体が合図になる
        switch (insertion.method, insertion.reason) {
        case (.none, let reason?): overlay.showToast(reason)
        case (.none, nil): if !sends { overlay.showToast(Messages.accessibilityDenied) }
        case (.ax, let reason?): overlay.showToast(post.command == .send ? Messages.unverifiedNotSent : reason)
        case (.ax, nil), (.paste, _): if let formatNote { overlay.showToast(formatNote) }
        }
        if !AXIsProcessTrusted() { openPrivacySettings("Privacy_Accessibility") }
    }

    /// 許可が無いと知らせた後、少し置いて該当の設定を開く。先にトーストを読めるように間を空ける。
    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            NSWorkspace.shared.open(url)
        }
    }

    private func fail(_ message: String) {
        overlay.closeCaption()
        overlay.showToast(message)
    }

    /// 書けなかったら理由を出して false を返す。
    @discardableResult
    private func record(_ entry: some Encodable) -> Bool {
        guard config.history.enabled else { return true }
        do {
            try HistoryWriter(url: AppPaths.history).append(entry)
            return true
        } catch {
            overlay.showToast(Messages.historyFailed(error.localizedDescription))
            return false
        }
    }
}
