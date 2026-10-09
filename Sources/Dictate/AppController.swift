import AppKit
@preconcurrency import AVFoundation
import Carbon.HIToolbox
import DictateKit
import SpeechCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private let menu = NSMenu()

    private var state = State.idle
    private var config = Config()
    private var dictionary = YomiDictionary(entries: [])
    private var hotKey: (any HotkeyListener)?
    private var recorder: HotkeyRecorder?
    /// これより短く離した押下は誤操作として、何も出さずに捨てる。
    private static let minimumHold = Duration.milliseconds(300)
    private var loadError: String?
    private var formatterReachable: Bool?
    private let formatterServer = FormatterServer(logURL: AppPaths.formatterLog)
    /// 接続できないときの知らせと自動起動は、オンにしたときと起動時に一度だけ行う。
    /// 他の設定を切り替えるたびには繰り返さず、やり直しはメニューの「整形サーバを起動」で本人が行う
    private var formatterAttempted = false
    /// nil は確認中。
    private var modelInstalled: Bool?
    private var lastUtterance: String?

    init(demo: Bool) {
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictate")
        formatterServer.onExit = { [weak self] state in
            guard let self, case .failed(let detail) = state else { return }
            formatterReachable = false
            overlay.showToast(Messages.formatterExited(detail))
        }
        // メニューは開く直前（menuNeedsUpdate）にだけ組む。許可の状態を開いた時点の値で出せる
        menu.delegate = self
        statusItem.menu = menu
        reload()
        guard !demo else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophone()
        }
        requestAccessibility()
        // マイクとアクセシビリティは OS が求めるが、認識モデルの未導入は誰も知らせない。起動時に一度だけ知らせる
        checkModel(notifyIfMissing: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        formatterServer.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
        // 結果は非同期に届く。メニューの追跡中は MainActor の Task が動かないので、次に開いたときに反映される
        if !demo { checkModel(notifyIfMissing: false) }
    }

    /// 日本語の認識モデルが入っているかを確かめる。
    private func checkModel(notifyIfMissing: Bool) {
        Task {
            modelInstalled = await LiveTranscriber().isModelInstalled()
            if notifyIfMissing, modelInstalled == false { overlay.showToast(Messages.modelNotInstalled) }
        }
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
        ensureFormatter()
    }

    /// 整形が有効なら接続を確かめ、できなければ起動コマンドがあるときはサーバを起動し、無いときは知らせる。
    /// 無効にしたら、アプリが起動したサーバを止める。デモ再生では何もしない。
    private func ensureFormatter() {
        guard !demo, loadError == nil, config.formatter.enabled else {
            formatterServer.stop()
            formatterAttempted = false
            return
        }
        if case .starting = formatterServer.state { return }
        let client = LLMClient(config.formatter)
        Task {
            let reachable = await client.isReachable()
            guard config.formatter.enabled else { return }  // 確かめている間にオフにされた
            formatterReachable = reachable
            if reachable {
                // 本人が立てたサーバに届いたなら、前の失敗の表示は要らない
                if case .failed = formatterServer.state { formatterServer.stop() }
                formatterAttempted = false
                return
            }
            guard !formatterAttempted else { return }
            formatterAttempted = true
            if let command = config.formatter.startCommand {
                startFormatterServer(command)
            } else {
                overlay.showToast(Messages.formatterUnreachable)
            }
        }
    }

    /// サーバを起動し、待ち受けが開くまで 1 秒ごとに確かめる。
    /// 待ち受けはモデルの読み込みより先に開くので、開かないのはポート違いかハングであり、60 秒で諦める。
    private func startFormatterServer(_ command: String) {
        Task {
            // 実行ファイルが無いときは、起動して 127 で落とすより先に入れ方を示す
            guard await FormatterServer.isExecutableAvailable(command) else {
                overlay.showToast(Messages.formatterCommandMissing(FormatterServer.executableName(of: command)))
                return
            }
            guard config.formatter.enabled else { return }
            let launched: Bool
            do {
                launched = try formatterServer.start(command: command)
            } catch {
                overlay.showToast(Messages.formatterStartFailed(error.localizedDescription))
                return
            }
            guard launched else { return }  // 起動中か動作中
            overlay.showToast(Messages.formatterStarting)
            let client = LLMClient(config.formatter)
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                // オフにされた（stopped）か、自分から終わった（failed。知らせは onExit）
                guard case .starting = formatterServer.state else { return }
                if await client.isReachable() {
                    formatterServer.markRunning()
                    formatterReachable = true
                    overlay.showToast(Messages.formatterReady)
                    // 最初の発話が予算に入るように、ここで一度温める。終わらなければモデルの読み込み中（初回はダウンロード）
                    if (try? await client.format("えっと、準備です")) == nil, case .running = formatterServer.state {
                        overlay.showToast(Messages.formatterLoading)
                    }
                    return
                }
            }
            guard case .starting = formatterServer.state else { return }
            formatterServer.fail("サーバの待ち受けが 60 秒たっても開かない")
            formatterReachable = false
            overlay.showToast(Messages.formatterStartTimedOut)
        }
    }

    @objc private func openLocalLLMGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Rererr/dictate/blob/main/docs/local-llm.md")!)
    }

    @objc private func startFormatterServerFromMenu() {
        guard let command = config.formatter.startCommand else { return }
        startFormatterServer(command)
    }

    @objc private func openFormatterLog() {
        NSWorkspace.shared.open(AppPaths.formatterLog)
    }

    private func buildMenu() {
        menu.removeAllItems()
        let accessibilityTrusted = AXIsProcessTrusted()
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

        if recorder != nil {
            info("ホットキーの登録中です。窓を閉じるまで、音声入力は止まっています")
        } else if let loadError {
            info("設定エラーのため停止中: \(loadError)")
        } else if demo {
            info("デモ再生（マイクと認識は使いません）")
        } else {
            info("ホットキー: \(config.hotkey.displayName) を押している間")
            info("マイク: \(microphoneStatus.label)")
            info("アクセシビリティ: \(accessibilityTrusted ? "許可済み" : "未許可（挿入できません）")")
            info("日本語の認識モデル: \(modelInstalled.map { $0 ? "導入済み" : "未導入（認識できません）" } ?? "確認中")")
            let reachability = switch (formatterServer.state, formatterReachable) {
            case (.starting(let since), _): "サーバを起動中 \(Int(Date().timeIntervalSince(since))) 秒。接続できるまで整形前の文を挿入します"
            case (.failed(let detail), _): "\(detail)。整形前の文を挿入します"
            case (_, .some(true)): "接続可"
            case (_, .some(false)): "接続不可。整形前の文を挿入します"
            case (_, .none): "接続を確認中"
            }
            info(config.formatter.enabled ? "整形: 有効（\(reachability)）" : "整形: 無効")
            info("履歴: \(config.history.enabled ? "有効" : "無効")")
            info("辞書: \(dictionary.isEmpty ? "なし" : "読み込み済み")")
        }
        menu.addItem(.separator())
        if !demo {
            // 足りないものがあるときだけ、その設定へ行く項目を出す
            var fixes: [(title: String, selector: Selector)] = []
            switch microphoneStatus {
            case .notDetermined: fixes.append(("マイクの許可を求める", #selector(requestMicrophone)))
            case .denied: fixes.append(("マイクの設定を開く", #selector(openMicrophoneSettings)))
            case .authorized, .restricted: break
            }
            if !accessibilityTrusted {
                fixes.append(("アクセシビリティの設定を開く", #selector(openAccessibilitySettings)))
                // アドホック署名で組み直すと、一覧ではオンのまま効かなくなる。記録を消して付け直す
                fixes.append(("アクセシビリティの許可を付け直す（オンに見えて効かないとき）", #selector(resetAccessibility)))
            }
            if modelInstalled == false { fixes.append(("音声入力の設定を開く（日本語を追加）", #selector(openDictationSettings))) }
            for fix in fixes { _ = action(fix.title, fix.selector) }
            if !fixes.isEmpty { menu.addItem(.separator()) }
        }
        if demo {
            for (index, scenario) in DemoScenario.all.enumerated() {
                action(scenario.title, #selector(playDemo(_:))).tag = index
            }
            menu.addItem(.separator())
        }
        if loadError == nil, !demo {
            action("発話の後に改行する", #selector(toggleNewlineAfterUtterance)).state = config.newlineAfterUtterance ? .on : .off
            action("LLM で整える（フィラーと句読点）", #selector(toggleFormatter)).state = config.formatter.enabled ? .on : .off
            // 接続できないときだけ、起動とログの項目を出す
            if config.formatter.enabled, formatterReachable != true {
                switch formatterServer.state {
                case .stopped, .failed:
                    if config.formatter.startCommand != nil { _ = action("整形サーバを起動", #selector(startFormatterServerFromMenu)) }
                case .starting, .running:
                    break
                }
                if FileManager.default.fileExists(atPath: AppPaths.formatterLog.path) {
                    _ = action("整形サーバのログを開く", #selector(openFormatterLog))
                }
                _ = action("ローカル LLM の手引きを開く", #selector(openLocalLLMGuide))
            }
        }
        _ = action(recorder == nil ? "ホットキーを登録…" : "ホットキーの登録の窓を前に出す", #selector(registerHotkey))
        _ = action("設定ファイルを開く", #selector(openConfigFile))
        _ = action("設定と辞書を再読み込み", #selector(reload))
        _ = action(lastUtterance == nil ? "直前の発話をコピー（まだありません）" : "直前の発話をコピー", #selector(copyLastUtterance), enabled: lastUtterance != nil)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private enum MicrophoneStatus {
        case authorized, notDetermined, denied
        /// 管理者の設定で禁じられている。利用者はシステム設定で変えられない。
        case restricted

        var label: String {
            switch self {
            case .authorized: "許可済み"
            case .notDetermined: "未許可（まだ求めていません）"
            case .denied: "未許可（録音できません）"
            case .restricted: "管理者の設定で使えません"
            }
        }
    }

    private var microphoneStatus: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    @objc private func requestMicrophone() {
        Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    @objc private func openMicrophoneSettings() {
        openSettings(Self.microphonePane)
    }

    @objc private func openAccessibilitySettings() {
        openSettings(Self.accessibilityPane)
    }

    private func requestAccessibility() {
        // 文字列は kAXTrustedCheckOptionPrompt の値。定数は並行性検査を通らない
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func openDictationSettings() {
        openSettings(Self.dictationPane)
    }

    /// 自分の許可の記録を OS から消してから、起動し直す。
    /// 記録を消すと一覧からも消え、同じプロセスからの求め直しは効かないことがある（別の Mac で実測）。
    /// 起動時の求め直しは確実に一覧へ戻すので、再起動で付け直せる状態にする。
    @objc private func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", "com.rererr.dictate"]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            overlay.showToast(Messages.accessibilityResetFailed(error.localizedDescription))
            return
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            overlay.showToast(Messages.accessibilityResetFailed(detail.isEmpty ? "tccutil が \(process.terminationStatus) で終了" : detail))
            return
        }
        overlay.showToast(Messages.accessibilityReset)
        Task {
            try? await Task.sleep(for: .seconds(2))  // 先にトーストを読めるように
            relaunch()
        }
    }

    /// 自分を終了し、別のプロセスから開き直す。終了直後は LaunchServices が open を拒むことがあるので、数回まで試す。
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for _ in 1 2 3 4 5; do sleep 1; open \"$DICTATE_BUNDLE\" && exit; done"]
        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_BUNDLE"] = Bundle.main.bundleURL.path
        process.environment = environment
        do {
            try process.run()
        } catch {
            overlay.showToast(Messages.relaunchFailed(error.localizedDescription))
            return
        }
        NSApp.terminate(nil)
    }

    @objc private func registerHotkey() {
        if let recorder {
            recorder.bringToFront()
            return
        }
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
            openSettings(Self.microphonePane, afterToast: true)
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
        if !AXIsProcessTrusted() { openSettings(Self.accessibilityPane, afterToast: true) }
    }

    private static let microphonePane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    private static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    /// キーボードの設定を、音声入力の節が見える位置で開く（macOS 27 で確認）
    private static let dictationPane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"

    /// システム設定の該当の画面を開く。トーストの後に開くときは、先に読めるように少し置く。
    private func openSettings(_ pane: String, afterToast: Bool = false) {
        guard let url = URL(string: pane) else { return }
        guard afterToast else {
            NSWorkspace.shared.open(url)
            return
        }
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
