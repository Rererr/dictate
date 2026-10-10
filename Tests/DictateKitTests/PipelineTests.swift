import Foundation
import SpeechCore
import Testing
@testable import DictateKit

/// 認識結果の文字列から、挿入する文、送るコマンド、知らせることが決まるまでを、実動作と同じ順
/// （辞書 → コマンド → フィラーの規則 → LLM 整形 → 予算 → 挿入の規則）で通す。
/// LLM はサーバの代わりに固定の応答を返し、挿入は結果（経路と理由）を与える。判断は AppController.finish と同じ InsertionRules を通る。
@Suite struct 発話から挿入までの一連 {
    let dictionary = YomiDictionary(entries: [.init(surface: "経管栄養"), .init(surface: "Laravel", reading: "ららべる")])

    struct Result: Equatable {
        let text: String
        let command: VoiceCommand?
        let formatStatus: FormatStatus?
        let sends: Bool
        let outcome: InsertionOutcome
    }

    func run(
        _ recognized: String, budget: Double = 1, newlineAfterUtterance: Bool = false, accessibilityTrusted: Bool = true,
        insertion: (String) -> UtteranceRecord.Insertion = { _ in .init(method: .paste, reason: "テスト") },
        llm: @escaping @Sendable (String) async throws -> String
    ) async -> Result {
        let post = postprocess(recognized, dictionary: dictionary)
        var text = post.body
        var status: FormatStatus?
        if !post.body.isEmpty {
            let formatting = Task.detached { await formatVerified(post.body, using: llm) }
            let inBudget = await outcome(of: formatting, within: budget)
            if let inBudget, inBudget.status == .adopted, let output = inBudget.output {
                text = output
                status = .adopted
            } else {
                status = inBudget?.status ?? .timedOut
            }
        }
        let result = text.isEmpty ? UtteranceRecord.Insertion(method: .none, reason: nil) : insertion(text)
        let command = InsertionRules.command(spoken: post.command, newlineAfterUtterance: newlineAfterUtterance, text: text)
        let sends = InsertionRules.sends(command: command, text: text, insertion: result, accessibilityTrusted: accessibilityTrusted)
        let outcome = InsertionRules.outcome(text: text, insertion: result, command: command, sends: sends, formatSkipped: status == .adopted ? nil : status)
        return Result(text: text, command: command, formatStatus: status, sends: sends, outcome: outcome)
    }

    @Test func 辞書とコマンドとフィラーの規則を通した本文を整形して採用し送信する() async {
        let result = await run("えっと、軽管栄養は 14時に実施、ララベルのキューも見ました、送信して") { masked in
            #expect(masked == "経管栄養は <N1>時に実施、Laravelのキューも見ました")
            return "経管栄養は<N1>時に実施。Laravelのキューも見ました。"
        }
        #expect(result == Result(text: "経管栄養は14時に実施。Laravelのキューも見ました。", command: .send, formatStatus: .adopted, sends: true, outcome: .silent))
    }

    @Test func 整形が内容を変えたら整形前の本文を入れて理由を知らせる() async {
        let result = await run("水分は150、改行して") { _ in "水分は<N1>ミリリットル。" }
        #expect(result == Result(text: "水分は150", command: .newline, formatStatus: .rejected, sends: true, outcome: .formatSkipped(.rejected)))
    }

    @Test func 整形が予算に間に合わなければ待たずに整形前の本文を入れる() async {
        let started = ContinuousClock.now
        let result = await run("了解です", budget: 0.05) { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return "了解です。"
        }
        #expect((ContinuousClock.now - started) < .milliseconds(200), "予算を超えたら LLM の完了を待たない")
        #expect(result.text == "了解です")
        #expect(result.outcome == .formatSkipped(.timedOut))
    }

    @Test func サーバに届かなければ整形前の本文を入れる() async {
        let result = await run("了解です") { _ in throw URLError(.cannotConnectToHost) }
        #expect(result.text == "了解です")
        #expect(result.outcome == .formatSkipped(.unreachable))
    }

    @Test func フィラーだけの発話は整形を呼ばず何も入れずフィラーだけと知らせる() async {
        let result = await run("えっと、あのー") { _ in
            Issue.record("本文が空のときは LLM を呼ばない")
            return ""
        }
        #expect(result == Result(text: "", command: nil, formatStatus: nil, sends: false, outcome: .nothingToInsert))
    }

    @Test func コマンドだけの発話は何も入れずキーだけ送る() async {
        let trusted = await run("送信して") { _ in "" }
        #expect(trusted == Result(text: "", command: .send, formatStatus: nil, sends: true, outcome: .silent))
        // キーを送る権限が無ければ、送れなかったと知らせる（フィラーだけの発話とは区別する）
        let untrusted = await run("送信して", accessibilityTrusted: false) { _ in "" }
        #expect(untrusted.sends == false)
        #expect(untrusted.outcome == .notInserted(reason: nil))
    }

    @Test func 発話の後に改行する設定は本文のある発話にだけ改行を送る() async {
        let text = await run("了解です", newlineAfterUtterance: true) { _ in "了解です。" }
        #expect(text.command == .newline)
        #expect(text.sends)
        let spoken = await run("了解です、送信して", newlineAfterUtterance: true) { _ in "了解です。" }
        #expect(spoken.command == .send, "話したコマンドを優先する")
        let empty = await run("えっと", newlineAfterUtterance: true) { _ in "" }
        #expect(empty.command == nil)
    }

    @Test func 挿入できなければ理由を知らせ入ったと確かめられなければ送信を見送る() async {
        let denied = await run("了解です", insertion: { _ in .init(method: .none, reason: "許可なし") }) { _ in "了解です。" }
        #expect(denied.outcome == .notInserted(reason: "許可なし"))
        let unverified = await run("了解です、送信して", insertion: { _ in .init(method: .ax, reason: "確認できない") }) { _ in "了解です。" }
        #expect(unverified.sends == false)
        #expect(unverified.outcome == .unverified(reason: "確認できない", sendSkipped: true))
        let ax = await run("了解です", insertion: { _ in .init(method: .ax, reason: nil) }) { _ in "了解です。" }
        #expect(ax.outcome == .silent)
    }

    @Test func 規則が残した曖昧語をLLMが消した出力は棄却する() async {
        // 「あのララベルの」は読点が無いので規則では残る。検証は読点つきの「あの、」しか認めない
        let result = await run("あのLaravelのキューが詰まっている") { _ in "Laravelのキューが詰まっている。" }
        #expect(result.formatStatus == .rejected)
        #expect(result.text == "あのLaravelのキューが詰まっている")
        // 読点つきなら規則が先に消すので、LLM は句読点だけを整える
        let withComma = await run("あの、Laravelのキューが詰まっている") { masked in
            #expect(masked == "Laravelのキューが詰まっている")
            return "Laravelのキューが詰まっている。"
        }
        #expect(withComma.text == "Laravelのキューが詰まっている。")
    }
}
