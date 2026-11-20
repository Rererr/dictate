import Foundation
import SpeechCore
import Testing
@testable import DictateKit

/// 規則（ADR-14）を通した後の本文に対して、LLM 整形が追加で何を直せるかを実機の履歴で測る。
/// 比較のため、規則を通す前の本文（formatter_bench.py が測っていた条件）も同じ LLM に通す。
/// 本文は出力せず、件数と所要だけを出す。履歴を送る計測は環境変数 DICTATE_LLM_BENCH=1 のときだけ走り（増減の数え方のテストは常に走る）、
/// サーバは DICTATE_LLM_BENCH_ENDPOINT（既定 http://127.0.0.1:8131/v1）に立っているものを使う。
/// 測るモデルは DICTATE_LLM_BENCH_MODELS（カンマ区切り）で指定し、未指定なら既定の 4B と 8B。
/// DICTATE_LLM_BENCH_JSON を指定すると、件数と発話ごとの所要（本文は含まない）を JSON でも書き出す。
/// 採用で本文が変わった発話は、句読点と空白の増減を境目ごとに数える（eval/punct_reference.tsv の方針に照らすため）。
@Suite struct 整形の二段目の実測 {
    static let optedIn = ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH"] == "1"
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH_ENDPOINT"] ?? "http://127.0.0.1:8131/v1")!
    static let models: [String] = {
        let names = (ProcessInfo.processInfo.environment["DICTATE_LLM_BENCH_MODELS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? [Config.Formatter.smallModel, Config.Formatter.largeModel] : names
    }()

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

    /// 境目は、句読点と空白を除いた字の間（i 字目の前。最後の境目が文末）。句読点は 、。？！ にそろえて数える
    static let kinds: [Character: Character] = ["、": "、", "，": "、", "。": "。", "．": "。", "？": "？", "！": "！"]

    static func boundaries(_ text: String) -> (base: [Character], marks: [(punctuation: Set<Character>, spaces: Set<Character>)]) {
        var base: [Character] = []
        var marks: [(punctuation: Set<Character>, spaces: Set<Character>)] = [([], [])]
        for ch in text {
            if let kind = kinds[ch] { marks[marks.count - 1].punctuation.insert(kind) }
            else if FormatVerifier.punctuation.contains(ch) { marks[marks.count - 1].spaces.insert(ch) }
            else { base.append(ch); marks.append(([], [])) }
        }
        return (base, marks)
    }

    /// 半角と全角の英字・数字。空白を足した所や消した所が、英数字の隣かを見る
    static func isAlphanumeric(_ ch: Character) -> Bool {
        guard ch.isLetter || ch.isNumber, let scalar = ch.unicodeScalars.first else { return false }
        return scalar.isASCII || (0xFF10...0xFF5A).contains(scalar.value)
    }

    /// 句読点と空白の増減。回数は境目の数、utterances… は発話の数
    struct Changes: Encodable, Equatable {
        var innerCommaAdded = 0, innerCommaRemoved = 0, innerPeriodAdded = 0, innerPeriodRemoved = 0
        var innerOtherAdded = 0, innerOtherRemoved = 0
        /// 文末に足した記号は 。 → ？！ → 、 の順に 1 つに数える
        var endAdded = 0, endAddedPeriod = 0, endAddedQuestion = 0, endAddedComma = 0, endRemoved = 0, endReplaced = 0
        /// 足した空白は、字の種類（改行・タブ → 全角 → 半角の順）と、置いた所（出力の同じ境目に句読点 → 英数字の隣 → それ以外の順）で 1 つずつ数える
        var spaceAdded = 0, spaceAddedHalfWidth = 0, spaceAddedFullWidth = 0, spaceAddedNewlineOrTab = 0
        var spaceAddedAtPunctuation = 0, spaceAddedNextToAlphanumeric = 0, spaceAddedElsewhere = 0
        var commaToSpace = 0
        var spaceRemovedAtPunctuation = 0, spaceRemovedAlone = 0, spaceRemovedAloneNextToAlphanumeric = 0, spaceRemovedAloneElsewhere = 0
        /// 曖昧語（あの・その・なんか・まあ）の直後に読点を足した回数。規則が消せる形になるので語彙の出現が増える
        var commaAfterAmbiguous = 0
        var utterancesOnlyAdded = 0, utterancesOnlyRemoved = 0, utterancesAddedAndRemoved = 0, utterancesOnlyEndAdded = 0
        /// 方針（空白は入力のまま残し、句読点を置いた所だけ消す。文末は句読点で終える）に反する変更を含む発話。
        /// 空白を足した・句読点の無い境目で空白を消した・文末の句読点を消した、のどれか
        var utterancesAgainstPolicy = 0
    }

    static func tally(input: String, output: String, into c: inout Changes) {
        let (base, before) = boundaries(input), (_, after) = boundaries(output)
        precondition(before.count == after.count, "検証を通った出力なのに、句読点と空白を除いた字が入力と違う")
        var added = false, removed = false, against = false, onlyEnd = true
        for i in before.indices {
            let b = before[i], a = after[i]
            let gained = a.punctuation.subtracting(b.punctuation), lost = b.punctuation.subtracting(a.punctuation)
            let nextToAlphanumeric = (i > 0 && isAlphanumeric(base[i - 1])) || (i < base.count && isAlphanumeric(base[i]))
            if i == base.count {
                if b.punctuation.isEmpty && !a.punctuation.isEmpty {
                    c.endAdded += 1; added = true
                    if a.punctuation.contains("。") { c.endAddedPeriod += 1 }
                    else if a.punctuation.contains("？") || a.punctuation.contains("！") { c.endAddedQuestion += 1 }
                    else { c.endAddedComma += 1 }
                }
                else if !b.punctuation.isEmpty && a.punctuation.isEmpty { c.endRemoved += 1; removed = true; against = true }
                else if !gained.isEmpty || !lost.isEmpty { c.endReplaced += 1; added = true; removed = true }
            } else {
                for kind in gained {
                    switch kind { case "、": c.innerCommaAdded += 1; case "。": c.innerPeriodAdded += 1; default: c.innerOtherAdded += 1 }
                }
                for kind in lost {
                    switch kind { case "、": c.innerCommaRemoved += 1; case "。": c.innerPeriodRemoved += 1; default: c.innerOtherRemoved += 1 }
                }
                if gained.contains("、"), FillerRules.ambiguous.contains(where: { String(base[..<i]).hasSuffix($0) }) { c.commaAfterAmbiguous += 1 }
                if !gained.isEmpty { added = true; onlyEnd = false }
                if !lost.isEmpty { removed = true; onlyEnd = false }
            }
            if !a.spaces.isEmpty && b.spaces.isEmpty {
                c.spaceAdded += 1; added = true; against = true; onlyEnd = false
                if !a.spaces.isDisjoint(with: ["\n", "\r", "\r\n", "\t"]) { c.spaceAddedNewlineOrTab += 1 }
                else if a.spaces.contains("　") { c.spaceAddedFullWidth += 1 }
                else { c.spaceAddedHalfWidth += 1 }
                if !a.punctuation.isEmpty { c.spaceAddedAtPunctuation += 1 }
                else if nextToAlphanumeric { c.spaceAddedNextToAlphanumeric += 1 }
                else { c.spaceAddedElsewhere += 1 }
                if lost.contains("、") { c.commaToSpace += 1 }
            }
            if !b.spaces.isEmpty && a.spaces.isEmpty {
                removed = true; onlyEnd = false
                if !a.punctuation.isEmpty { c.spaceRemovedAtPunctuation += 1 }
                else {
                    c.spaceRemovedAlone += 1; against = true
                    if nextToAlphanumeric { c.spaceRemovedAloneNextToAlphanumeric += 1 } else { c.spaceRemovedAloneElsewhere += 1 }
                }
            }
        }
        switch (added, removed) {
        case (true, false): c.utterancesOnlyAdded += 1; if onlyEnd { c.utterancesOnlyEndAdded += 1 }
        case (false, true): c.utterancesOnlyRemoved += 1
        case (true, true): c.utterancesAddedAndRemoved += 1
        case (false, false): break
        }
        if against { c.utterancesAgainstPolicy += 1 }
    }

    struct Summary: Encodable {
        var adopted = 0, rejected = 0, unreachable = 0
        var fillersBefore = 0, fillersAfter = 0, fillersRemovedInAdopted = 0, fillersIncreasedInAdopted = 0
        var changedInAdopted = 0, punctuationOnlyInAdopted = 0
        /// アプリは予算を過ぎた結果を挿入しない（afterBudget）。挿入されるのは採用かつ予算内のもの
        var withinBudget = 0, adoptedWithinBudget = 0
        var changes = Changes()
        var seconds: [Double] = []
    }

    struct Output: Encodable {
        struct Record: Encodable { let model: String, condition: String, total: Int, budgetSeconds: Double, summary: Summary }
        let utterances: Int, ruledUtterances: Int
        var records: [Record] = []
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
            if result.seconds <= settings.budgetSeconds {
                summary.withinBudget += 1
                if result.status == .adopted { summary.adoptedWithinBudget += 1 }
            }
            switch result.status {
            case .adopted:
                summary.adopted += 1
                let output = result.output ?? text
                let after = fillerTokens(in: output)
                summary.fillersAfter += after
                summary.fillersRemovedInAdopted += before - after
                if after > before { summary.fillersIncreasedInAdopted += 1 }
                if output != text {
                    summary.changedInAdopted += 1
                    tally(input: text, output: output, into: &summary.changes)
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
        let c = s.changes
        return """
        \(label): 採用 \(s.adopted)/\(total)、棄却 \(s.rejected)、接続不可 \(s.unreachable)
          語彙の出現: 送る前 \(s.fillersBefore) → 採用後 \(s.fillersAfter)（採用で消えた \(s.fillersRemovedInAdopted)。検証が認めないので 0 のはず）
          採用のうち本文が変わった \(s.changedInAdopted)（句読点と空白だけ \(s.punctuationOnlyInAdopted)）。語彙の出現が増えた発話 \(s.fillersIncreasedInAdopted)
          増減（境目の数）: 文中の読点 +\(c.innerCommaAdded)/-\(c.innerCommaRemoved)、文中の句点 +\(c.innerPeriodAdded)/-\(c.innerPeriodRemoved)、文中の？！ +\(c.innerOtherAdded)/-\(c.innerOtherRemoved)
            文末 +\(c.endAdded)（。\(c.endAddedPeriod)・？！\(c.endAddedQuestion)・、\(c.endAddedComma)）/-\(c.endRemoved)（置き換え \(c.endReplaced)）
            空白を足した \(c.spaceAdded)（半角 \(c.spaceAddedHalfWidth)・全角 \(c.spaceAddedFullWidth)・改行かタブ \(c.spaceAddedNewlineOrTab)／句読点の所 \(c.spaceAddedAtPunctuation)・英数字の隣 \(c.spaceAddedNextToAlphanumeric)・それ以外 \(c.spaceAddedElsewhere)／読点から \(c.commaToSpace)）
            空白を消した: 句読点のある所 \(c.spaceRemovedAtPunctuation)・句読点の無い所 \(c.spaceRemovedAlone)（英数字の隣 \(c.spaceRemovedAloneNextToAlphanumeric)・それ以外 \(c.spaceRemovedAloneElsewhere)）。曖昧語の直後に読点 +\(c.commaAfterAmbiguous)
          発話: 足しただけ \(c.utterancesOnlyAdded)（文末だけ \(c.utterancesOnlyEndAdded)）、消しただけ \(c.utterancesOnlyRemoved)、両方 \(c.utterancesAddedAndRemoved)。方針に反する変更を含む \(c.utterancesAgainstPolicy)
          所要: 中央値 \(String(format: "%.2f", median)) 秒、最大 \(String(format: "%.2f", max)) 秒、予算内 \(s.withinBudget)/\(total)（採用かつ予算内 \(s.adoptedWithinBudget)）
        """
    }

    @Test func 句読点と空白の増減を境目ごとに数える() {
        func changes(_ input: String, _ output: String) -> Changes {
            var c = Changes()
            Self.tally(input: input, output: output, into: &c)
            return c
        }
        #expect(changes("了解です午後に対応します", "了解です。午後に対応します。")
                == Changes(innerPeriodAdded: 1, endAdded: 1, endAddedPeriod: 1, utterancesOnlyAdded: 1))
        #expect(changes("ご確認をお願いいたします", "ご確認をお願いいたします。")
                == Changes(endAdded: 1, endAddedPeriod: 1, utterancesOnlyAdded: 1, utterancesOnlyEndAdded: 1))
        #expect(changes("いいですか", "いいですか？") == Changes(endAdded: 1, endAddedQuestion: 1, utterancesOnlyAdded: 1, utterancesOnlyEndAdded: 1))
        #expect(changes("いいですか。", "いいですか？") == Changes(endReplaced: 1, utterancesAddedAndRemoved: 1))
        #expect(changes("あの件です", "あの、件です") == Changes(innerCommaAdded: 1, commaAfterAmbiguous: 1, utterancesOnlyAdded: 1))
        // 方針どおり: 空白の所に読点を置いて空白を消す
        #expect(changes("血圧は 120 の 78 脈拍は 72", "血圧は 120 の 78、脈拍は 72。")
                == Changes(innerCommaAdded: 1, endAdded: 1, endAddedPeriod: 1, spaceRemovedAtPunctuation: 1, utterancesAddedAndRemoved: 1))
        // 方針に反する: 空白を足す、句読点の無い所で空白を消す、読点を空白に替える、文末の句点を消す
        #expect(changes("15時から", "15 時から")
                == Changes(spaceAdded: 1, spaceAddedHalfWidth: 1, spaceAddedNextToAlphanumeric: 1, utterancesOnlyAdded: 1, utterancesAgainstPolicy: 1))
        #expect(changes("了解です午後", "了解です。\n午後")
                == Changes(innerPeriodAdded: 1, spaceAdded: 1, spaceAddedNewlineOrTab: 1, spaceAddedAtPunctuation: 1, utterancesOnlyAdded: 1, utterancesAgainstPolicy: 1))
        #expect(changes("PR 3113 を見ます", "PR3113を見ます。")
                == Changes(endAdded: 1, endAddedPeriod: 1, spaceRemovedAlone: 2, spaceRemovedAloneNextToAlphanumeric: 2,
                           utterancesAddedAndRemoved: 1, utterancesAgainstPolicy: 1))
        #expect(changes("明日、レビューします。", "明日 レビューします")
                == Changes(innerCommaRemoved: 1, endRemoved: 1, spaceAdded: 1, spaceAddedHalfWidth: 1, spaceAddedElsewhere: 1, commaToSpace: 1,
                           utterancesAddedAndRemoved: 1, utterancesAgainstPolicy: 1))
    }

    @Test(.enabled(if: optedIn, "DICTATE_LLM_BENCH=1 のときだけ走る"), .timeLimit(.minutes(30)))
    func 規則の後段としての効果を履歴で測る() async throws {
        let raw = try Self.utterances()
        let ruled = raw.map { FillerRules.remove(from: $0) }.filter { !$0.isEmpty }
        var report = "履歴の発話 \(raw.count) 件。規則で語彙の出現 \(raw.map(Self.fillerTokens).reduce(0, +)) → \(ruled.map(Self.fillerTokens).reduce(0, +))\n"
        var output = Output(utterances: raw.count, ruledUtterances: ruled.count)
        let budget = Config.Formatter().budgetSeconds
        for model in Self.models {
            report += "\n[\(model)]\n"
            for (condition, texts) in [("規則の前（formatter_bench の条件）", raw), ("規則の後（アプリの実際の条件）", ruled)] {
                let summary = await Self.run(texts, model: model)
                report += Self.describe(condition, summary, total: texts.count) + "\n"
                output.records.append(.init(model: model, condition: condition, total: texts.count, budgetSeconds: budget, summary: summary))
            }
        }
        print(report)
        let environment = ProcessInfo.processInfo.environment
        if let out = environment["DICTATE_LLM_BENCH_OUT"] { try report.write(toFile: out, atomically: true, encoding: .utf8) }
        if let json = environment["DICTATE_LLM_BENCH_JSON"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(output).write(to: URL(fileURLWithPath: json))
        }
    }
}
