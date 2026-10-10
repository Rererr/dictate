import Foundation
import SpeechCore
import Testing
@testable import DictateKit

@Suite struct 末尾コマンド {
    let dictionary = YomiDictionary(entries: [.init(surface: "経管栄養")])

    @Test func 末尾の送信してを本文から除きコマンドにする() {
        let result = postprocess("さっきの件、明日の朝一でレビューお願いできますか。送信して", dictionary: dictionary)
        #expect(result.body == "さっきの件、明日の朝一でレビューお願いできますか。")
        #expect(result.command == .send)
    }

    @Test func 末尾の句読点と区切りの読点があっても判定する() {
        let result = postprocess("了解です、午後に対応します、送信して。", dictionary: dictionary)
        #expect(result.body == "了解です、午後に対応します")
        #expect(result.command == .send)
    }

    @Test func 末尾の改行してを本文から除き改行のコマンドにする() {
        let result = postprocess("了解です、午後に対応します。改行して。", dictionary: dictionary)
        #expect(result.body == "了解です、午後に対応します。")
        #expect(result.command == .newline)
        #expect(postprocess("改行して", dictionary: dictionary).body.isEmpty)
    }

    @Test func 同じ読みに誤認識された末尾のコマンドも判定する() {
        let result = postprocess("テストです。開業して", dictionary: dictionary)
        #expect(result.body == "テストです。")
        #expect(result.command == .newline)
    }

    @Test(arguments: ["ここで改行してから続きを書きます。", "改行を入れてください。", "改行", "テストです。開業してテストです。"])
    func 末尾でない改行の語は本文として残す(text: String) {
        let result = postprocess(text, dictionary: dictionary)
        #expect(result.body == text)
        #expect(result.command == nil)
    }

    @Test func 文中の送信しては本文として残す() {
        let text = "このファイルを送信してから、もう一度連絡します。"
        let result = postprocess(text, dictionary: dictionary)
        #expect(result.body == text)
        #expect(result.command == nil)
    }

    @Test func 送信してだけなら本文は空になる() {
        let result = postprocess("送信して。", dictionary: dictionary)
        #expect(result.body.isEmpty)
        #expect(result.command == .send)
    }

    @Test func 辞書置換をコマンド判定より先に行う() {
        let result = postprocess(" 軽管栄養は実施。送信して", dictionary: dictionary)
        #expect(result.afterDictionary == "経管栄養は実施。送信して")
        #expect(result.body == "経管栄養は実施。")
        #expect(result.replacements.count == 1)
    }
}

@Suite struct 数値マスク {
    @Test func 数字と数字に挟まれた記号を印に置き換え元に戻せる() {
        let mask = NumberMask("血圧は120/78、体温は36.5、PR 3113、１４時")
        #expect(mask.masked == "血圧は<N1>、体温は<N2>、PR <N3>、<N4>時")
        #expect(mask.unmask("血圧は<N1>。体温は<N2>、PR <N3>、<N4>時") == "血圧は120/78。体温は36.5、PR 3113、１４時")
    }

    @Test func 数字に挟まれていない語はマスクしない() {
        #expect(NumberMask("120の78").masked == "<N1>の<N2>")
    }

    @Test(arguments: ["血圧は<N1>", "<N2>と<N1>", "<N1>と<N2>と<N3>", "<N1>と<N1>と<N2>"])
    func 印が欠けた増えた入れ替わった出力は戻さない(output: String) {
        #expect(NumberMask("120と78").unmask(output) == nil)
    }
}

@Suite struct 整形の差分検証 {
    @Test(arguments: [
        ("えっと、本番デプロイは<N1>時からでいいですか", "本番デプロイは<N1>時からでいいですか。"),
        ("えー見積書を添付いたしましたのでご確認をお願いいたします", "見積書を添付いたしましたので、ご確認をお願いいたします。"),
        ("あの、キューが詰まっているみたいです", "キューが詰まっているみたいです。"),
        ("栄養は <N1>時に実施", "栄養は<N1>時に実施。"),
        ("変更なし。", "変更なし。"),
    ])
    func 句読点と空白の変更とフィラーの削除は通す(input: String, output: String) {
        #expect(FormatVerifier.accepts(input: input, output: output))
    }

    @Test(arguments: [
        ("さっきの件なんですけど明日レビューお願いできますか", "明日レビューお願いできますか。"),
        ("水分は<N1>", "水分は<N1>ミリリットル。"),
        ("<N1>の<N2>", "<N1>/<N2>"),
        ("火曜じゃなくて水曜でお願いします", "水曜でお願いします。"),
        ("あの件はその後どうですか", "件は後どうですか。"),
        ("お願いできますか", "お願いします。"),
    ])
    func 内容の削除と追加と書き換えは通さない(input: String, output: String) {
        #expect(!FormatVerifier.accepts(input: input, output: output))
    }

    @Test(arguments: ["えーと、明日行きます", "えーっと、明日行きます", "ええと、明日行きます"])
    func えーとの表記ゆれもフィラーとして削除を認める(input: String) {
        #expect(FormatVerifier.accepts(input: input, output: "明日行きます。"))
    }

    @Test(arguments: [("えーと、明日行きます", "と、明日行きます。"), ("あのー、明日行きます", "ー、明日行きます。")])
    func フィラーの一部だけを削った出力は通さない(input: String, output: String) {
        #expect(!FormatVerifier.accepts(input: input, output: output))
    }

    @Test func 読点が続かないあのとそのは削除を認めない() {
        #expect(!FormatVerifier.accepts(input: "あの件です", output: "件です"))
        #expect(FormatVerifier.accepts(input: "その、件です", output: "件です"))
    }
}

@Suite struct 整形の一連 {
    @Test func 検証を通った出力は数値を戻して採用する() async {
        let result = await formatVerified("えっと、PRは3113です") { masked in
            #expect(masked == "えっと、PRは<N1>です")
            return "PRは<N1>です。"
        }
        #expect(result.status == .adopted)
        #expect(result.output == "PRは3113です。")
    }

    @Test func 単位を補った出力は棄却し出力を記録に残す() async {
        let result = await formatVerified("水分は150") { _ in "水分は<N1>ミリリットル。" }
        #expect(result.status == .rejected)
        #expect(result.output == "水分は<N1>ミリリットル。")
    }

    @Test(arguments: [
        ("3、4人です", "<N1><N2>人です"),
        ("3 4人です", "<N1><N2>人です"),
        ("1 2です", "<N1>．<N2>です"),
        ("3. 5です", "<N1>.<N2>です"),
    ])
    func 隣り合う数値の間の記号と空白を変えた出力は棄却する(input: String, output: String) async {
        let result = await formatVerified(input) { _ in output }
        #expect(result.status == .rejected)
    }

    @Test func 数値の間に語があれば句読点の変更は通す() async {
        let result = await formatVerified("えっと、14時から30分です") { _ in "<N1>時から、<N2>分です。" }
        #expect(result.output == "14時から、30分です。")
    }

    @Test(arguments: [("えっと", ""), ("えー、あのー", "。")])
    func フィラーだけの発話を空にした出力は採用しない(input: String, output: String) async {
        let result = await formatVerified(input) { _ in output }
        #expect(result.status == .rejected)
    }

    @Test func 印を増やした出力は棄却する() async {
        let result = await formatVerified("水分は150") { _ in "水分は<N1>、<N2>。" }
        #expect(result.status == .rejected)
    }

    @Test func サーバに届かなければ接続不可とし理由を残す() async {
        let result = await formatVerified("こんにちは") { _ in throw URLError(.cannotConnectToHost) }
        #expect(result.status == .unreachable)
        #expect(result.detail != nil)
    }

    @Test func 予算内に終われば値を返し超えればnilを返すが処理は止めない() async {
        let fast = Task { 1 }
        #expect(await outcome(of: fast, within: 1) == 1)
        let slow = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(300))
            return 2
        }
        #expect(await outcome(of: slow, within: 0.05) == nil)
        #expect(await slow.value == 2)
    }

    @Test func 予算を超えて届いた採用結果は時間切れとして残す() {
        let late = FormatResult(status: .adopted, output: "a", detail: nil, seconds: 1.5).afterBudget()
        #expect(late.status == .timedOut)
        #expect(late.output == "a")
        #expect(FormatResult(status: .rejected, output: "b", detail: nil, seconds: 1.5).afterBudget().status == .rejected)
    }
}

@Suite struct フィラーの規則 {
    @Test func 曖昧でない語はどこにあっても直後の読点ごと消す() {
        #expect(FillerRules.remove(from: "えっと、本番デプロイは15時からでいいですか") == "本番デプロイは15時からでいいですか")
        #expect(FillerRules.remove(from: "えっと本番でプロイは 15時から") == "本番でプロイは 15時から")
        #expect(FillerRules.remove(from: "えー、見積書を添付いたしました") == "見積書を添付いたしました")
        #expect(FillerRules.remove(from: "あのー、来週の水曜日") == "来週の水曜日")
        #expect(FillerRules.remove(from: "えーっと、朝食は、えーと、全量") == "朝食は、全量")
        #expect(FillerRules.remove(from: "ええと、確認します") == "確認します")
    }

    @Test func 曖昧な語は文頭か句読点の直後で読点が続くときだけ消す() {
        #expect(FillerRules.remove(from: "あの、Laravel のキューが詰まっている") == "Laravel のキューが詰まっている")
        #expect(FillerRules.remove(from: "なんか、PR のテストが落ちている") == "PR のテストが落ちている")
        #expect(FillerRules.remove(from: "まあ、ステージングで再現できました") == "ステージングで再現できました")
        #expect(FillerRules.remove(from: "そうだね。その、次の一手を") == "そうだね。次の一手を")
        // 残すもの: 連体詞と副詞、読点の無いもの、文中のもの
        #expect(FillerRules.remove(from: "あの人が来た") == "あの人が来た")
        #expect(FillerRules.remove(from: "あのララベルの球が詰まって") == "あのララベルの球が詰まって")
        #expect(FillerRules.remove(from: "そうだね。その次の一手を") == "そうだね。その次の一手を")
        #expect(FillerRules.remove(from: "またその、精度を高める") == "またその、精度を高める")
        #expect(FillerRules.remove(from: "まあまあの出来です") == "まあまあの出来です")
        #expect(FillerRules.remove(from: "なんか変だ") == "なんか変だ")
    }

    @Test func 後処理で既定で効き設定で切れる() {
        let dictionary = YomiDictionary(entries: [])
        let on = postprocess("えっと、了解です。送信して", dictionary: dictionary)
        #expect(on.body == "了解です。")
        #expect(on.command == .send)
        #expect(on.removedFillers == 4)
        let off = postprocess("えっと、了解です。送信して", dictionary: dictionary, removeFillers: false)
        #expect(off.body == "えっと、了解です。")
        #expect(off.removedFillers == 0)
    }
}

@Suite struct 設定 {
    func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func ファイルが無ければ既定値で動く() throws {
        let config = try Config.load(from: URL(filePath: "/nonexistent/config.json"))
        #expect(config == Config())
        #expect(config.hotkey.displayName == "⌃⌥⌘D")
        #expect(config.hotkey.trigger == .key(code: 2))
        #expect(!config.formatter.enabled)
        #expect(config.history.enabled)
    }

    @Test func 発話の後の改行は既定で無効で保存すると他の項目を残して切り替わる() throws {
        let url = try write(#"{"formatter": {"enabled": true}}"#)
        #expect(try !Config.load(from: url).newlineAfterUtterance)
        try Config.update(at: url) { $0.newlineAfterUtterance = true }
        let loaded = try Config.load(from: url)
        #expect(loaded.newlineAfterUtterance)
        #expect(loaded.formatter.enabled)
    }

    @Test func 起動コマンドは無いかnullなら既定で空なら起動しない() throws {
        #expect(try Config.load(from: write("{}")).formatter.startCommand == Config.Formatter.defaultStartCommand)
        #expect(try Config.load(from: write(#"{"formatter": {"startCommand": null}}"#)).formatter.startCommand == Config.Formatter.defaultStartCommand)
        #expect(try Config.load(from: write(#"{"formatter": {"startCommand": ""}}"#)).formatter.startCommand == nil)
        #expect(try Config.load(from: write(#"{"formatter": {"startCommand": " "}}"#)).formatter.startCommand == nil)
        let url = try write("{}")
        try Config.update(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""startCommand" : "mlx_lm.server"#))
        try Config.update(at: url) { $0.formatter.startCommand = "my_server --port 8124" }
        #expect(try Config.load(from: url).formatter.startCommand == "my_server --port 8124")
        try Config.update(at: url) { $0.formatter.startCommand = nil }
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""startCommand" : """#))
        #expect(try Config.load(from: url).formatter.startCommand == nil)
        try Config.update(at: url) { $0.formatter.startCommand = " \n" }
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""startCommand" : """#))
        var config = Config()
        config.formatter.startCommand = "  "
        #expect(config.formatter.startCommand == nil)
    }

    @Test func 設定ファイルを開くアプリは無ければnullで書き出し書けば読み直せる() throws {
        let url = try write("{}")
        try Config.update(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""editor" : null"#))
        try Config.update(at: url) { $0.editor = "/Applications/CotEditor.app" }
        #expect(try Config.load(from: url).editor == "/Applications/CotEditor.app")
    }

    @Test func 空の配列は改行を挟まずに書き出す() throws {
        let url = try write("{}")
        try Config.update(at: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains(#""alwaysPasteBundleIds" : []"#))
        #expect(json.contains(#""modifiers" : ["#))  // 既定のホットキーの修飾キーは空でない
        #expect(!json.contains(/\[\s*\n\s*\]/))
    }

    @Test func 書いた項目だけを上書きする() throws {
        let config = try Config.load(from: write(#"{"formatter": {"enabled": true}, "alwaysPasteBundleIds": ["com.example"]}"#))
        #expect(config.formatter.enabled)
        #expect(config.formatter.budgetSeconds == 1.0)
        #expect(config.alwaysPasteBundleIds == ["com.example"])
    }

    @Test func 型が違う項目は既定値に読み替えず箇所を示して失敗する() throws {
        let url = try write(#"{"formatter": {"enabled": "yes"}}"#)
        #expect { try Config.load(from: url) } throws: { error in
            guard case Config.LoadError.invalid(_, let detail) = error else { return false }
            return detail.contains("formatter.enabled")
        }
    }

    @Test(arguments: [
        (#"{"formater": {"enabled": true}}"#, "formater"),
        (#"{"formatter": {"enable": true}}"#, "formatter.enable"),
        (#"{"alwaysPasteBundleIDs": []}"#, "alwaysPasteBundleIDs"),
    ])
    func 打ち間違えた項目名は既定値に読み替えず箇所を示して失敗する(json: String, path: String) throws {
        let url = try write(json)
        #expect { try Config.load(from: url) } throws: { error in
            guard case Config.LoadError.invalid(_, let detail) = error else { return false }
            return detail.hasPrefix(path + ":")
        }
    }

    @Test func ホットキーはキーとマウスボタンのどちらも読める() throws {
        let key = try Config.load(from: write(#"{"hotkey": {"type": "key", "code": 38, "modifiers": ["option", "control"]}}"#))
        #expect(key.hotkey.trigger == .key(code: 38))
        #expect(key.hotkey.displayName == "⌃⌥J")
        let mouse = try Config.load(from: write(#"{"hotkey": {"type": "mouse", "button": 3}}"#))
        #expect(mouse.hotkey.trigger == .mouse(button: 3))
        #expect(mouse.hotkey.displayName == "マウスボタン 4")
        #expect(Config.Hotkey(trigger: .mouse(button: 2), modifiers: [.control]).displayName == "⌃中ボタン")
        #expect(Config.Hotkey(trigger: .key(code: 200), modifiers: [.command]).displayName == "⌘キーコード 200")
    }

    @Test(arguments: [
        (#"{"type": "key", "code": 2, "modifiers": []}"#, Config.Hotkey.Problem.needsModifier),
        (#"{"type": "key", "code": 2, "modifiers": ["shift"]}"#, .needsModifier),
        (#"{"type": "key", "code": 61, "modifiers": []}"#, .modifierKeyAlone),
        (#"{"type": "key", "code": 58, "modifiers": ["command"]}"#, .modifierKeyAlone),
        (#"{"type": "mouse", "button": 0, "modifiers": []}"#, .primaryMouseButton),
        (#"{"type": "mouse", "button": 1, "modifiers": ["control"]}"#, .primaryMouseButton),
    ])
    func 登録できないホットキーは理由つきで拒否する(json: String, problem: Config.Hotkey.Problem) throws {
        let url = try write(#"{"hotkey": \#(json)}"#)
        #expect(throws: Config.LoadError.hotkey(problem)) { try Config.load(from: url) }
    }

    @Test(arguments: [
        #"{"type": "key", "code": 79, "modifiers": []}"#,
        #"{"type": "key", "code": 2, "modifiers": ["shift", "command"]}"#,
        #"{"type": "mouse", "button": 2, "modifiers": []}"#,
        #"{"type": "mouse", "button": 4, "modifiers": ["option"]}"#,
    ])
    func ファンクションキーの単独とサイドボタンと修飾キーつきは登録できる(json: String) throws {
        #expect(try Config.load(from: write(#"{"hotkey": \#(json)}"#)).hotkey.problem == nil)
    }

    @Test func ホットキーの保存は他の項目を残し読み直すと同じ値になる() throws {
        let url = try write(#"{"formatter": {"enabled": true, "budgetSeconds": 2}, "alwaysPasteBundleIds": ["com.example"]}"#)
        let hotkey = Config.Hotkey(trigger: .mouse(button: 3), modifiers: [.command, .control])
        try Config.update(at: url) { $0.hotkey = hotkey }
        let loaded = try Config.load(from: url)
        #expect(loaded.hotkey == hotkey)
        #expect(loaded.hotkey.modifiers == [.control, .command])
        #expect(loaded.formatter.enabled)
        #expect(loaded.formatter.budgetSeconds == 2)
        #expect(loaded.alwaysPasteBundleIds == ["com.example"])
    }

    @Test func 設定ファイルが無くてもホットキーを保存できる() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)/config.json")
        try Config.update(at: url) { $0.hotkey = Config.Hotkey(trigger: .key(code: 38), modifiers: [.control, .option]) }
        #expect(try Config.load(from: url).hotkey.displayName == "⌃⌥J")
    }

    @Test func 壊れた設定ファイルにはホットキーを上書きしない() throws {
        let broken = #"{"formater": {"enabled": true}}"#
        let url = try write(broken)
        #expect(throws: Config.LoadError.self) { try Config.update(at: url) { $0.hotkey = Config.Hotkey() } }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    @Test(arguments: [
        #"{"budgetSeconds": -1}"#, #"{"budgetSeconds": 0}"#, #"{"budgetSeconds": 1e300}"#,
        #"{"temperature": -0.1}"#, #"{"temperature": 3}"#, #"{"maxTokens": 0}"#, #"{"maxTokens": 100000}"#,
    ])
    func 整形の設定が範囲外なら拒否する(formatter: String) throws {
        let url = try write(#"{"formatter": \#(formatter)}"#)
        #expect { try Config.load(from: url) } throws: { error in
            guard case Config.LoadError.formatter = error else { return false }
            return true
        }
    }

    @Test func 設定を書き出すと全項目が並び読み直しても同じ値になる() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)/config.json")
        try Config.update(at: url) {
            $0.formatter.enabled = true
            $0.formatter.temperature = 0.2
            $0.formatter.systemPrompt = "句読点だけ整える。"
        }
        let loaded = try Config.load(from: url)
        #expect(loaded.formatter.enabled)
        #expect(loaded.formatter.temperature == 0.2)
        #expect(loaded.formatter.systemPrompt == "句読点だけ整える。")
        #expect(loaded.formatter.maxTokens == 512)
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in ["hotkey", "newlineAfterUtterance", "alwaysPasteBundleIds", "history", "endpoint", "model", "budgetSeconds", "maxTokens", "enableThinking"] {
            #expect(text.contains("\"\(key)\""))
        }
    }

    @Test func プロンプトが未設定でも項目をnullで書き出す() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)/config.json")
        try Config.update(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"systemPrompt\" : null"))
        #expect(try Config.load(from: url) == Config())
    }
}

@Suite struct 履歴 {
    @Test func 発話と整形を1行ずつ追記する() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)/history.jsonl")
        let writer = HistoryWriter(url: url)
        let post = postprocess("軽管栄養は実施。送信して", dictionary: YomiDictionary(entries: [.init(surface: "経管栄養")]))
        try writer.append(UtteranceRecord(
            id: "u1", startedAt: Date(timeIntervalSince1970: 0), recordingSeconds: 2.5, raw: "軽管栄養は実施。送信して",
            runs: [Run(text: "軽管", confidence: 0.5, timeRange: 0...0.4)], post: post, inserted: post.body,
            insertion: .init(method: .paste, reason: "AX 不可"), app: "com.example",
            timings: .init(releaseToFinal: 0.1, postprocess: 0.01, insert: 0.3)
        ))
        try writer.append(FormatRecord(utteranceId: "u1", result: FormatResult(status: .timedOut, output: "x", detail: nil, seconds: 1.4)))

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let utterance = try decoder.decode(UtteranceRecord.self, from: Data(lines[0].utf8))
        #expect(utterance.type == "utterance")
        #expect(utterance.command == .send)
        #expect(utterance.inserted == "経管栄養は実施。")
        #expect(utterance.insertion.method == .paste)
        #expect(utterance.runs.first?.end == 0.4)
        let format = try decoder.decode(FormatRecord.self, from: Data(lines[1].utf8))
        #expect(format.type == "format")
        #expect(format.status == .timedOut)
    }
}

@Suite struct 整形サーバ {
    private func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dictate-\(name)-\(UUID().uuidString)/formatter.log")
    }

    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 監視シェルの子（サーバ本体）の pid。まだ無ければ nil。
    private func childProcess(of shell: Int32) -> Int32? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(shell)]
        let output = Pipe()
        pgrep.standardOutput = output
        try? pgrep.run()
        pgrep.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { Int32($0) }.first
    }

    @MainActor @Test func 自分から終わったサーバは失敗として残り出力はログに残る() async throws {
        let server = FormatterServer(logURL: url("exit"))
        var reported: FormatterServer.State?
        server.onExit = { reported = $0 }
        #expect(try server.start(command: "echo hello; exit 3"))
        guard case .starting = server.state else { Issue.record("起動直後は starting"); return }
        await wait { if case .failed = server.state { true } else { false } }
        #expect(server.state == .failed("サーバの起動に失敗（終了コード 3）"))
        #expect(reported == server.state)
        let log = try String(contentsOf: server.logURL, encoding: .utf8)
        #expect(log.hasPrefix("$ echo hello; exit 3\n"))
        #expect(log.contains("hello"))
    }

    @MainActor @Test func 動作中に終わったサーバはそう区別して残る() async throws {
        let server = FormatterServer(logURL: url("running"))
        try server.start(command: "sleep 0.5")
        server.markRunning()
        await wait { if case .failed = server.state { true } else { false } }
        #expect(server.state == .failed("サーバが動作中に終了（終了コード 0）"))
    }

    @MainActor @Test func 止めるとサーバ本体のプロセスも消え失敗にはならない() async throws {
        let server = FormatterServer(logURL: url("stop"))
        try server.start(command: "sleep 30")
        let shell = try #require(server.processIdentifier)
        await wait { childProcess(of: shell) != nil }  // ログインシェルの初期化が終わり、サーバ本体が動き出すまで
        let child = try #require(childProcess(of: shell))
        server.stop()
        #expect(server.state == .stopped)
        await wait { kill(child, 0) != 0 && kill(shell, 0) != 0 }
        #expect(kill(child, 0) != 0)
        #expect(kill(shell, 0) != 0)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(server.state == .stopped)
    }

    @MainActor @Test func 起動中はもう一度起動しても二つ目を作らない() async throws {
        let server = FormatterServer(logURL: url("twice"))
        #expect(try server.start(command: "sleep 30"))
        let pid = server.processIdentifier
        #expect(try !server.start(command: "sleep 30"))
        #expect(server.processIdentifier == pid)
        server.stop()
    }

    @Test func 起動コマンドの実行ファイルの有無をログインシェルで確かめる() async {
        #expect(FormatterServer.executableName(of: "mlx_lm.server --model x --port 8124") == "mlx_lm.server")
        #expect(await FormatterServer.isExecutableAvailable("ls -la"))
        #expect(await !FormatterServer.isExecutableAvailable("dictate_nonexistent_server_xyz --port 1"))
        #expect(await !FormatterServer.isExecutableAvailable(""))
    }

    @MainActor @Test func 諦めると止めてから失敗として残す() async throws {
        let server = FormatterServer(logURL: url("fail"))
        try server.start(command: "sleep 30")
        let shell = try #require(server.processIdentifier)
        server.fail("サーバの待ち受けが 60 秒たっても開かない")
        #expect(server.state == .failed("サーバの待ち受けが 60 秒たっても開かない"))
        #expect(server.processIdentifier == nil)
        await wait { kill(shell, 0) != 0 }
        #expect(kill(shell, 0) != 0)
    }
}
