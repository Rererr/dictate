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

    @Test func TSVは読みを省略でき空行とコメントを読み飛ばす() {
        let parsed = YomiDictionary.parse(tsv: "# 介護\n経管栄養\n\nLaravel\tららべる\n")
        #expect(parsed.dictionary.apply("軽管栄養とララベル").text == "経管栄養とLaravel")
        #expect(parsed.skipped.isEmpty)
    }

    @Test func TSVはCRLFとBOMがあっても効く() {
        let parsed = YomiDictionary.parse(tsv: "\u{FEFF}経管栄養\r\nLaravel\tららべる\r\n")
        #expect(parsed.dictionary.apply("軽管栄養とララベル").text == "経管栄養とLaravel")
    }

    @Test func TSVの読めない行は行番号と理由を残して読み飛ばし残りの行で辞書を作る() {
        let parsed = YomiDictionary.parse(tsv: "経管栄養\na\tb\tc\nLaravel\tららべる\nー")
        #expect(parsed.dictionary.apply("軽管栄養とララベル").text == "経管栄養とLaravel")
        #expect(parsed.skipped == [.malformedLine(number: 2, content: "a\tb\tc"), .emptyKey(number: 4, surface: "ー")])
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

@Suite struct 読みの検索 {
    @Test func 読みだけの辞書で原文の出現を数える() {
        let matcher = YomiDictionary.matcher(readings: ["かいぎょう"])
        #expect(matcher.occurrences(in: "改行します。開業の日に改行した") == ["改行", "開業", "改行"])
        #expect(matcher.occurrences(in: "海洋の話").isEmpty)
    }

    @Test func 平仮名の読みは正規化しても変わらない() {
        #expect(YomiDictionary.reading(of: "りょうみん") == "りょうみん")
        #expect(YomiDictionary.reading(of: "ゆかづれ") == "ゆかづれ")
    }

    @Test func 語の切り出しは原文の範囲と読みを持つ() {
        let words = YomiDictionary.words(of: "領民が良い")
        #expect(words.map(\.text) == ["領民", "が", "良い"])
        #expect(words.first?.reading == "りょうみん")
        #expect(words.allSatisfy { String("領民が良い"[$0.range]) == $0.text })
    }
}
