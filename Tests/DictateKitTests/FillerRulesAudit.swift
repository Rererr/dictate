import Foundation
import SpeechCore
import Testing
@testable import DictateKit

/// 現在のフィラー規則（ADR-14）を履歴と台本にかけ、消えた区間だけを前後 4 文字つきで列挙する（一時的な監査。本文は出さない）。
@Suite struct フィラー規則の監査 {
    static let optedIn = ProcessInfo.processInfo.environment["DICTATE_FILLER_AUDIT"] == "1"
    struct Row: Decodable { let type: String; let afterDictionary: String? }

    static let script = [
        "さっきの件、明日の朝一でレビューお願いできますか。", "PR 3113のテストが落ちているので、原因を見てからもう一度プッシュします。",
        "えっと、本番デプロイは15時からでいいですか。", "ステージングで再現できました。マイグレーションの順序が原因です。",
        "了解です、午後に対応します。", "このファイルを送信してから、もう一度連絡します。",
        "あの、Laravelのキューが詰まっているみたいなので、ワーカーを再起動します。",
        "お世話になっております。先日ご相談いただいた件について、ご連絡いたします。",
        "来週の水曜日、14時から30分ほどお時間をいただけますでしょうか。", "えー、見積書を添付いたしましたので、ご確認をお願いいたします。",
        "ご指摘の不具合は、10月15日のリリースで修正する予定です。", "お手数をおかけしますが、ご検討のほどよろしくお願いいたします。",
        "請求金額は税込みで12万8千円です。", "朝食は主食が全量、副食が半分で、水分は150。", "血圧は120の78、脈拍は72、体温は36度5分。",
        "山田さん、排泄介助、排尿あり、褥瘡なし。", "経管栄養は14時に実施、特に変わりなし。", "えっと、入浴後に仙骨部の発赤を確認、看護師に報告。",
        "昼食後に嚥下体操を実施、むせ込みなし。", "夜間は巡視3回、良眠されていた。",
        "えっと、本番デプロイは15時からでいいですか", "あの、Laravel のキューが詰まっているみたいなので、ワーカーを再起動します",
        "さっきの件、明日の朝一でレビューお願いできますか", "えー、見積書を添付いたしましたので、ご確認をお願いいたします",
        "まあ、ステージングで再現できましたマイグレーションの順序が原因です", "なんか、PR 3113 のテストが落ちているので原因を見てからもう一度プッシュします",
        "お世話になっております先日ご相談いただいた件についてご連絡いたします", "えっと、入浴後に仙骨部の発赤を確認看護師に報告",
        "血圧は 120 の 78 脈拍は 72 体温は 36 度 5 分", "あのー、来週の水曜日 14 時から 30 分ほどお時間をいただけますでしょうか",
        "了解です午後に対応します", "えーっと、朝食は主食が全量副食が半分で水分は 150",
    ]

    /// 消えた区間を、元の文での前後 4 文字と一緒に返す。
    static func removedSpans(_ text: String) -> [String] {
        let after = FillerRules.remove(from: text)
        guard after != text else { return [] }
        let a = Array(text), b = Array(after)
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        var j = 0
        while j < min(a.count, b.count) - i, a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let removed = String(a[i..<(a.count - j)])
        let before = String(a[max(0, i - 4)..<i]), afterText = String(a[(a.count - j)..<min(a.count, a.count - j + 4)])
        return ["\(before)【\(removed)】\(afterText)"]
    }

    @Test(.enabled(if: optedIn, "DICTATE_FILLER_AUDIT=1 のときだけ走る"))
    func 消えた区間を列挙する() throws {
        let url = AppPaths.history
        let history = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), row.type == "utterance" else { return nil }
            return row.afterDictionary
        }
        var report = "履歴 \(history.count) 発話\n"
        for text in history { for span in Self.removedSpans(text) { report += "  \(span)\n" } }
        report += "台本 \(Self.script.count) 文\n"
        for text in Self.script { for span in Self.removedSpans(text) { report += "  \(span)\n" } }
        print(report)
        if let out = ProcessInfo.processInfo.environment["DICTATE_FILLER_AUDIT_OUT"] { try report.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
