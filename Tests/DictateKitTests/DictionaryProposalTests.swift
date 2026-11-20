import Foundation
import Testing
import SpeechCore
@testable import DictateKit

/// 直した文との差分から辞書の行を提案する（ADR-18）。
@Suite struct 辞書の行の提案 {
    @Test func 同音の誤表記を直すと直した表記と誤表記の読みを提案する() {
        let proposals = DictionaryProposal.propose(original: "領民が良い状態です", corrected: "良眠が良い状態です")
        #expect(proposals == [DictionaryProposal(wrong: "領民", surface: "良眠", reading: "りょうみん")])
    }

    @Test func 語の途中の差分は語の境界まで広げ左隣の本文の語も含める() {
        // 「連れ」だけの行は「連れて行く」も壊すので、「床連れ」を区間にする
        let proposals = DictionaryProposal.propose(original: "床連れがある", corrected: "床ずれがある")
        #expect(proposals.map(\.wrong) == ["床連れ"])
        #expect(proposals.map(\.surface) == ["床ずれ"])
        #expect(proposals.first?.reading == YomiDictionary.reading(of: "床連れ"))
    }

    @Test func 右隣の語には広げない() {
        // 「床連れ予防マット」まで含めると「床連れがある」に効かない
        #expect(DictionaryProposal.propose(original: "床連れ予防マットを使う", corrected: "床ずれ予防マットを使う").map(\.wrong) == ["床連れ"])
    }

    @Test func 平仮名を含む語の手前で止まる() {
        #expect(DictionaryProposal.propose(original: "明日は開業します", corrected: "明日は改行します") == [DictionaryProposal(wrong: "開業", surface: "改行", reading: "かいぎょう")])
        #expect(DictionaryProposal.propose(original: "新しい資料を作成した", corrected: "新しい試料を作成した").map(\.wrong) == ["資料"])
    }

    @Test func 離れた二つの区間は別の行になる() {
        let proposals = DictionaryProposal.propose(original: "極東の処置と軽管栄養", corrected: "褥瘡の処置と経管栄養")
        #expect(proposals.count == 2)
        #expect(proposals[0] == DictionaryProposal(wrong: "極東", surface: "褥瘡", reading: "きょくとう"))
        // 「軽管」は語でないので「軽」「管」に砕ける。右の 1 文字の破片は含め、独立した語「栄養」は含めない
        #expect(proposals[1] == DictionaryProposal(wrong: "軽管", surface: "経管", reading: "けいかん"))
    }

    /// 広げた区間の中に、長さの違う変更（長音の削除や挿入）があっても、直した側の範囲がずれない
    @Test(arguments: [
        ("ジョブ級サーバー", "ジョブキューサーバ", "ジョブ級", "ジョブキュー"),
        ("ウェブサーバー構蓄", "ウェブサーバ構築", "ウェブサーバー構蓄", "ウェブサーバ構築"),
        ("ウェブサーバ構蓄", "ウェブサーバー構築", "ウェブサーバ構蓄", "ウェブサーバー構築"),
        ("極東予防マットレスを使う", "褥瘡予防マットを使う", "極東", "褥瘡"),
    ])
    func 区間の中の挿入と削除があっても直した側の範囲が合う(original: String, corrected: String, wrong: String, surface: String) {
        let proposals = DictionaryProposal.propose(original: original, corrected: corrected)
        #expect(proposals.map(\.wrong) == [wrong])
        #expect(proposals.map(\.surface) == [surface])
    }

    @Test(arguments: [
        ("床連れ", "床ずれがある", "床連れ", "床ずれ"),  // 直後の挿入は含めない
        ("床連れ予防", "床ずれの予防", "床連れ", "床ずれ"),
        ("極東処置", "褥瘡の処置", "極東", "褥瘡"),  // 差分が「褥瘡の」にまとまる。末尾の平仮名は助詞と見て外す
        ("極東の処置", "褥瘡への処置", "極東", "褥瘡"),
    ])
    func 区間の外の挿入と助詞は表記に入れない(original: String, corrected: String, wrong: String, surface: String) {
        let proposals = DictionaryProposal.propose(original: original, corrected: corrected)
        #expect(proposals.map(\.wrong) == [wrong])
        #expect(proposals.map(\.surface) == [surface])
    }

    @Test func 同じ誤りが繰り返されても行は一つ() {
        #expect(DictionaryProposal.propose(original: "軽管栄養と軽管", corrected: "経管栄養と経管").count == 1)
    }

    @Test func 漢数字を含む語は提案する() {
        #expect(DictionaryProposal.propose(original: "一部解除で歩く", corrected: "一部介助で歩く").map(\.surface) == ["一部介助"])
    }

    @Test(arguments: [
        ("了解です午後に対応します", "了解です。午後に対応します"),  // 句読点だけ
        ("血圧は 120 の 78", "血圧は 120 の 78"),  // 変更なし
        ("1020の78です", "120の78です"),  // 算用数字
        ("本番デプロイは", "本番デプロイは15時から"),  // 挿入だけ
        ("えっと本番デプロイは", "本番デプロイは"),  // 削除だけ
        ("😀です", "😃です"),  // 読みが仮名にならない
        ("", "何か"), ("何か", ""),
    ])
    func 辞書で直せない差分は提案しない(original: String, corrected: String) {
        #expect(DictionaryProposal.propose(original: original, corrected: corrected).isEmpty)
    }

    @Test func 全部違う文でも落ちず共通の助詞で区間が分かれる() {
        let proposals = DictionaryProposal.propose(original: "朝の申し送り", corrected: "夜勤の記録")
        #expect(proposals.map(\.wrong) == ["朝", "申し送り"])
        #expect(proposals.map(\.surface) == ["夜勤", "記録"])
    }

    @Test func 揃え方は最長共通部分列で区間と対応を返す() {
        let alignment = DictionaryProposal.Alignment(Array("abcdef"), Array("abXdeYf"))
        #expect(alignment.changes.map { "\($0.old)" } == ["2..<3", "5..<5"])
        #expect(alignment.changes.map { "\($0.new)" } == ["2..<3", "5..<6"])
        #expect(alignment.newRange(of: 2..<3) == 2..<3)
        #expect(alignment.newRange(of: 0..<6) == 0..<7)
        #expect(alignment.newRange(of: 3..<6) == 3..<7, "内側の挿入（Y）は含める")
        #expect(alignment.newRange(of: 3..<5) == 3..<5, "直後の挿入（Y）は含めない")
    }
}

@Suite struct 読みの出現 {
    @Test func 履歴の挿入文で読みが現れた表記を回数の多い順に数える() {
        let usage = ReadingUsage.of(reading: "かいぎょう", in: ["改行します", "開業の日", "改行して", "海洋"])
        #expect(usage.surfaces.map(\.surface) == ["改行", "開業"])
        #expect(usage.surfaces.map(\.count) == [2, 1])
        #expect(usage.total == 3)
    }

    @Test func 複数の読みを一度に数え重複した読みでも落ちない() {
        let usages = ReadingUsage.of(readings: ["かいぎょう", "りょうみん", "りょうみん"], in: ["改行して領民が", "領民"])
        #expect(usages["かいぎょう"]?.total == 1)
        #expect(usages["りょうみん"]?.surfaces.first?.count == 2)
    }

    @Test func 直した表記以外の語があれば巻き込むと分かる() {
        // 「領民」を正しく使った箇所も、誤表記の側なので置き換わる
        #expect(ReadingUsage.of(reading: "りょうみん", in: ["領民の暮らし"]).collides(with: "良眠"))
        // 直した表記そのものだけなら、置き換えても変わらない
        #expect(!ReadingUsage.of(reading: "かいぎょう", in: ["改行します"]).collides(with: "改行"))
        #expect(!ReadingUsage.of(reading: "かいぎょう", in: []).collides(with: "改行"))
    }

    @Test func 履歴は今のファイルと繰り越し分から発話の挿入文だけを読む() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "history.jsonl")
        let current = """
            {"type":"utterance","inserted":"新しい"}
            {"type":"format","output":"整形"}
            broken

            """
        try Data(current.utf8).write(to: url)
        try Data("{\"type\":\"utterance\",\"inserted\":\"古い\"}\n".utf8).write(to: url.appendingPathExtension("1"))
        #expect(HistoryReader.insertedTexts(at: url) == ["古い", "新しい"])
        #expect(HistoryReader.insertedTexts(at: dir.appending(path: "none.jsonl")).isEmpty)
    }
}

@Suite struct 辞書ファイルへの追記 {
    func file(_ content: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dictate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "dictionary.tsv")
        if let content { try Data(content.utf8).write(to: url) }
        return url
    }

    let rows = [DictionaryFile.Row(surface: "良眠", reading: "りょうみん")]
    /// 2025-10-09 05:33 UTC。日本時間なら同日 14:33 で、どちらの時間帯でも日付は変わらない
    let date = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func 無ければ作り日付のコメントに続けて行を書き読み直せる() throws {
        let url = try file(nil)
        try DictionaryFile.append(rows, to: url, date: date)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "# 2025-10-09 「直前の発話を直して辞書に足す」から\n良眠\tりょうみん\n")
        let parsed = YomiDictionary.parse(tsv: text)
        #expect(parsed.skipped.isEmpty)
        #expect(parsed.dictionary.apply("領民が").text == "良眠が")
    }

    @Test func 末尾に改行が無い辞書には改行を補ってから足し既存の行を残す() throws {
        let url = try file("\u{FEFF}床ずれ\tゆかづれ")
        try DictionaryFile.append(rows, to: url, date: date)
        // String(contentsOf:) は BOM を落とすので、バイト列で BOM が残ることを見る
        #expect(try Data(contentsOf: url).prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("床ずれ\tゆかづれ\n# 2025-10-09"))
        #expect(YomiDictionary.parse(tsv: text).skipped.isEmpty)
        #expect(YomiDictionary.parse(tsv: text).dictionary.apply("床連れと領民").text == "床ずれと良眠")
    }

    @Test func CRLFの辞書にはCRLFで足す() throws {
        let url = try file("経管栄養\r\n")
        try DictionaryFile.append(rows, to: url, date: date)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "経管栄養\r\n# 2025-10-09 「直前の発話を直して辞書に足す」から\r\n良眠\tりょうみん\r\n")
        #expect(YomiDictionary.parse(tsv: text).skipped.isEmpty)
    }

    @Test func UTF8でない辞書には書かない() throws {
        let url = try file(nil)
        let shiftJIS = try #require("床ずれ\tゆかづれ\n".data(using: .shiftJIS))
        try shiftJIS.write(to: url)
        #expect(throws: DictionaryFile.WriteError.notUTF8(path: url.path)) { try DictionaryFile.append(rows, to: url, date: date) }
        #expect(try Data(contentsOf: url) == shiftJIS)
    }

    @Test func 日付は地域の時間帯で書く() throws {
        let url = try file(nil)
        // 2025-10-09 23:30 UTC は日本時間で 10 月 10 日
        try DictionaryFile.append(rows, to: url, date: Date(timeIntervalSince1970: 1_760_052_600))
        let expected = Date(timeIntervalSince1970: 1_760_052_600).formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("# \(expected) "))
    }

    @Test func 読めるが書けないのでなく書けるが読めない辞書を上書きしない() throws {
        let url = try file("床ずれ\tゆかづれ\n経管栄養\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(throws: (any Error).self) { try DictionaryFile.append(rows, to: url, date: date) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try String(contentsOf: url, encoding: .utf8) == "床ずれ\tゆかづれ\n経管栄養\n")
    }

    @Test func NULを含むファイルはUTF8と見なさない() throws {
        let url = try file(nil)
        let utf16 = try #require("abc\n".data(using: .utf16LittleEndian))
        try utf16.write(to: url)
        #expect(throws: DictionaryFile.WriteError.notUTF8(path: url.path)) { try DictionaryFile.append(rows, to: url, date: date) }
        #expect(try Data(contentsOf: url) == utf16)
    }

    @Test func シャープで始まる表記は拒む() {
        #expect(DictionaryFile.problems(in: [DictionaryFile.Row(surface: "#タグ", reading: "たぐ")]).first?.contains("コメント") == true)
    }

    @Test func シンボリックリンクの先に足す() throws {
        let target = try file("経管栄養\n")
        let link = target.deletingLastPathComponent().appending(path: "link.tsv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try DictionaryFile.append(rows, to: link, date: date)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("良眠\tりょうみん"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test func 読めない行は理由を返して書かない() throws {
        let url = try file("経管栄養\n")
        let bad = [DictionaryFile.Row(surface: "良眠\n", reading: "りょうみん"), DictionaryFile.Row(surface: "ー", reading: "ー")]
        let problems = DictionaryFile.problems(in: bad)
        #expect(problems.count == 2)
        #expect(problems[0].contains("タブか改行"))
        #expect(problems[1].contains("読みを作れません"))
        #expect(throws: DictionaryFile.WriteError.self) { try DictionaryFile.append(bad, to: url, date: date) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "経管栄養\n")
    }
}
