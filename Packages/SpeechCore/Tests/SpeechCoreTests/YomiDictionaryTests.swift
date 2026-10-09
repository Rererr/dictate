import Testing
@testable import SpeechCore

@Suite struct YomiDictionaryTests {
    let dictionary = YomiDictionary(entries: [
        .init(surface: "経管栄養"),
        .init(surface: "褥瘡"),
        .init(surface: "Laravel", reading: "ららべる"),
    ])

    @Test func 読みが同じ誤表記を表記に置き換える() {
        let result = dictionary.apply("軽管栄養は14時に実施。")
        #expect(result.text == "経管栄養は14時に実施。")
        #expect(result.replacements == [.init(original: "軽管栄養", surface: "経管栄養")])
    }

    @Test func 正しい表記はそのまま残し置換として数えない() {
        let result = dictionary.apply("褥瘡なし、経管栄養は実施。")
        #expect(result.text == "褥瘡なし、経管栄養は実施。")
        #expect(result.replacements.isEmpty)
    }

    @Test func 読みまでずれた誤りは直らない() {
        #expect(dictionary.apply("経過栄養は実施。").text == "経過栄養は実施。")
    }

    @Test func 明示した読みで英字の表記に置き換える() {
        #expect(dictionary.apply("ララベルのキューが詰まっている").text == "Laravelのキューが詰まっている")
    }

    @Test func 句読点をまたぐ区間は一語として扱わない() {
        #expect(dictionary.apply("経管、栄養").text == "経管、栄養")
    }

    @Test(arguments: ["褥瘡 なし", "経管栄養は 14時", " 褥瘡", "ララベル のキュー"])
    func 語に隣り合う空白は置換区間に含めない(text: String) {
        let result = dictionary.apply(text)
        #expect(result.text == text.replacingOccurrences(of: "ララベル", with: "Laravel"))
        #expect(result.replacements.allSatisfy { !$0.original.contains(" ") })
    }

    @Test func 表記が同じで空白だけが隣にある語は置換として数えない() {
        #expect(dictionary.apply("褥瘡 なし、経管栄養は 14時に実施").replacements.isEmpty)
    }

    @Test func 辞書が空なら何も変えない() {
        let result = YomiDictionary(entries: []).apply("軽管栄養")
        #expect(result.text == "軽管栄養")
    }

    @Test func TSVは読みを省略でき空行とコメントを読み飛ばす() throws {
        let parsed = try YomiDictionary(tsv: "# 介護\n経管栄養\n\nLaravel\tららべる\n")
        #expect(parsed.apply("軽管栄養とララベル").text == "経管栄養とLaravel")
    }

    @Test func TSVはCRLFとBOMがあっても効く() throws {
        let parsed = try YomiDictionary(tsv: "\u{FEFF}経管栄養\r\nLaravel\tららべる\r\n")
        #expect(parsed.apply("軽管栄養とララベル").text == "経管栄養とLaravel")
    }

    @Test func TSVの列が多い行は行番号つきで拒否する() {
        #expect(throws: YomiDictionary.ParseError.malformedLine(number: 2, content: "a\tb\tc")) {
            try YomiDictionary(tsv: "経管栄養\na\tb\tc")
        }
    }
}

@Suite struct TranscriptAccumulatorTests {
    @Test func 確定区間を連結し部分結果を末尾に付ける() {
        var accumulator = TranscriptAccumulator()
        accumulator.apply(.volatile("今日は"))
        #expect(accumulator.text == "今日は")
        accumulator.apply(.final(FinalSegment(runs: [Run(text: "今日は晴れ。", confidence: 0.9, timeRange: 0...1)])))
        accumulator.apply(.volatile("明日"))
        #expect(accumulator.text == "今日は晴れ。明日")
        accumulator.apply(.final(FinalSegment(runs: [Run(text: "明日は雨。", confidence: nil, timeRange: nil)])))
        #expect(accumulator.finalText == "今日は晴れ。明日は雨。")
        #expect(accumulator.volatile.isEmpty)
        #expect(accumulator.runs.count == 2)
    }
}
