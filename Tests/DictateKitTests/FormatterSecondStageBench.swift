import Foundation
import SpeechCore
import Testing
@testable import DictateKit

/// 規則（ADR-14）を通した後の本文に対して、LLM 整形が追加で何を直せるかを実機の履歴で測る。
/// 比較のため、規則を通す前の本文（formatter_bench.py が測っていた条件）も同じ LLM に通す。
/// 本文は出力せず、件数と所要だけを出す。環境変数 DICTATE_LLM_BENCH=1 のときだけ走り、
/// サーバは DICTATE_LLM_BENCH_ENDPOINT（既定 http://127.0.0.1:8131/v1）に立っているものを使う。
@Suite struct 整形の二段目の実測 {
    static let optedIn = ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH"] == "1"
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH_ENDPOINT"] ?? "http://127.0.0.1:8131/v1")!

    struct Row: Decodable { let type: String; let afterDictionary: String? }

    static func utterances() throws -> [String] {
        let url = AppPaths.history
        let empty = YomiDictionary(entries: [])
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), row.type == "utterance",
                  let text = row.afterDictionary else { return nil }
            let body = postprocess(text, dictionary: empty, removeFillers: false).body
            return body.isEmpty ? nil : body
        }
    }

    /// 語彙の出現数。長い語から一度だけ消費して数える（「えーっと」を「えー」でも数えない）。
    /// 曖昧語は直後に読点があるものだけ数える（規則と検証が消せる範囲）。
    static func fillerTokens(in text: String) -> Int {
        var rest = text
        var count = 0
        for word in FillerRules.unambiguous.sorted(by: { $0.count > $1.count }) + FillerRules.ambiguous.map({ $0 + "、" }) {
            let parts = rest.components(separatedBy: word)
            count += parts.count - 1
            rest = parts.joined(separator: " ")
        }
        return count
    }

    struct Summary {
        var adopted = 0, rejected = 0, unreachable = 0
        var fillersBefore = 0, fillersAfter = 0, fillersRemovedInAdopted = 0
        var changedInAdopted = 0, punctuationOnlyInAdopted = 0
        var seconds: [Double] = []
    }

    static func run(_ texts: [String], model: String) async -> Summary {
        var settings = Config.Formatter()
        settings.endpoint = endpoint
        settings.model = model
        let client = LLMClient(settings)
        _ = try? await client.format("えっと、準備です")
        var summary = Summary()
        for text in texts {
            let before = fillerTokens(in: text)
            summary.fillersBefore += before
            let result = await formatVerified(text) { try await client.format($0) }
            summary.seconds.append(result.seconds)
            switch result.status {
            case .adopted:
                summary.adopted += 1
                let output = result.output ?? text
                let after = fillerTokens(in: output)
                summary.fillersAfter += after
                summary.fillersRemovedInAdopted += before - after
                if output != text {
                    summary.changedInAdopted += 1
                    if before == after { summary.punctuationOnlyInAdopted += 1 }
                }
            case .rejected: summary.rejected += 1; summary.fillersAfter += before
            default: summary.unreachable += 1; summary.fillersAfter += before
            }
        }
        return summary
    }

    static func describe(_ label: String, _ s: Summary, total: Int) -> String {
        let sorted = s.seconds.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let max = sorted.last ?? 0
        return """
        \(label): 採用 \(s.adopted)/\(total)、棄却 \(s.rejected)、接続不可 \(s.unreachable)
          語彙の出現: 送る前 \(s.fillersBefore) → 採用後 \(s.fillersAfter)（採用で消えた \(s.fillersRemovedInAdopted)。検証が認めないので 0 のはず）
          採用のうち本文が変わった \(s.changedInAdopted)（句読点と空白だけ \(s.punctuationOnlyInAdopted)）
          所要: 中央値 \(String(format: "%.2f", median)) 秒、最大 \(String(format: "%.2f", max)) 秒
        """
    }

    @Test(.enabled(if: optedIn, "DICTATE_LLM_BENCH=1 のときだけ走る"), .timeLimit(.minutes(30)))
    func 規則の後段としての効果を履歴で測る() async throws {
        let raw = try Self.utterances()
        let ruled = raw.map { FillerRules.remove(from: $0) }.filter { !$0.isEmpty }
        var report = "履歴の発話 \(raw.count) 件。規則で語彙の出現 \(raw.map(Self.fillerTokens).reduce(0, +)) → \(ruled.map(Self.fillerTokens).reduce(0, +))\n"
        for model in [Config.Formatter.smallModel, Config.Formatter.largeModel] {
            report += "\n[\(model)]\n"
            report += Self.describe("規則の前（formatter_bench の条件）", await Self.run(raw, model: model), total: raw.count) + "\n"
            report += Self.describe("規則の後（アプリの実際の条件）", await Self.run(ruled, model: model), total: ruled.count) + "\n"
        }
        print(report)
        let out = ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH_OUT"]
        if let out { try report.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
