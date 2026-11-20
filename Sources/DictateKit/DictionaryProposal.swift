import Foundation
import SpeechCore

/// 直した文との差分から出した、辞書の行の候補（ADR-18）。
public struct DictionaryProposal: Sendable, Hashable {
    /// 認識結果の側の区間（誤表記）。
    public let wrong: String
    /// 直した側の区間。辞書の表記の初期値。
    public let surface: String
    /// 誤表記の読み。辞書の照合キーと同じ関数で作る。
    public let reading: String

    public init(wrong: String, surface: String, reading: String) {
        self.wrong = wrong
        self.surface = surface
        self.reading = reading
    }

    /// 文字単位の差分を取り、変わった区間を単語境界まで広げ、左隣の語が漢字・カタカナ・英字だけの間はさらに広げる
    /// （「床連れ」→「床ずれ」の差分は「連れ」だが、「連れ」の行は「連れて行く」も壊すので「床連れ」にする）。
    /// 右には 1 文字の語だけ広げる。誤認識で砕けた複合語の破片（「軽管栄養」の「管」）は含め、
    /// 独立した語（「床連れ予防マット」の「予防」）は含めない。含めると「床連れがある」に効かない。
    /// 句読点と空白だけの違い、挿入だけ・削除だけの区間、算用数字を含む区間、読みが仮名にならない区間は提案しない。
    public static func propose(original: String, corrected: String) -> [DictionaryProposal] {
        let old = Array(original)
        let new = Array(corrected)
        let alignment = Alignment(old, new)
        let words = YomiDictionary.words(of: original).map { word in
            (range: original.distance(from: original.startIndex, to: word.range.lowerBound)..<original.distance(from: original.startIndex, to: word.range.upperBound),
             text: word.text,
             chainable: word.text.contains(where: \.isContentCharacter) && !word.text.contains(where: \.isHiragana))
        }

        // old の範囲だけを広げてまとめ、new の範囲は最後に対応表から引く（広げた幅を new に写すと、間の挿入・削除でずれる）
        var spans: [Range<Int>] = []
        for change in alignment.changes where !change.old.isEmpty && !change.new.isEmpty {
            var lower = change.old.lowerBound
            var upper = change.old.upperBound
            if let first = words.firstIndex(where: { $0.range.upperBound > lower && $0.range.lowerBound < upper }) {
                var start = first
                while start > 0, words[start - 1].chainable, words[start - 1].range.upperBound == words[start].range.lowerBound { start -= 1 }
                var end = words.lastIndex(where: { $0.range.lowerBound < upper }) ?? first
                while end + 1 < words.count, words[end + 1].chainable, words[end + 1].text.count == 1, words[end + 1].range.lowerBound == words[end].range.upperBound { end += 1 }
                lower = min(lower, words[start].range.lowerBound)
                upper = max(upper, words[end].range.upperBound)
            }
            if let last = spans.last, last.upperBound >= lower {
                spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                spans.append(lower..<upper)
            }
        }

        var seen: Set<DictionaryProposal> = []
        return spans.compactMap { span in
            let wrong = String(old[span])
            var surface = String(new[alignment.newRange(of: span)])
            // 「極東処置」→「褥瘡の処置」は差分が「極東」→「褥瘡の」にまとまる。誤表記が平仮名で終わらないなら、直した側の末尾の平仮名は助詞と見て外す
            if let lastWrong = wrong.last, !lastWrong.isHiragana {
                while let lastSurface = surface.last, lastSurface.isHiragana { surface.removeLast() }
            }
            guard !wrong.isEmpty, !surface.isEmpty,
                  wrong.filter({ !FormatVerifier.punctuation.contains($0) }) != surface.filter({ !FormatVerifier.punctuation.contains($0) }),
                  !wrong.contains(where: \.isDecimalDigit)
            else { return nil }
            let reading = YomiDictionary.reading(of: wrong)
            guard !reading.isEmpty, reading.allSatisfy(\.isHiragana) else { return nil }
            let proposal = DictionaryProposal(wrong: wrong, surface: surface, reading: reading)
            // 同じ発話に同じ誤りが繰り返されても、行は 1 つ
            return seen.insert(proposal).inserted ? proposal : nil
        }
    }

    /// 最長共通部分列で old と new を揃えた結果。old の位置から new の位置を引ける。
    struct Alignment {
        let oldCount: Int
        let newCount: Int
        /// 変わっていない文字の対応（old の位置の昇順）。
        let matches: [(old: Int, new: Int)]
        /// 変わった区間（old か new に文字があるもの）。
        let changes: [(old: Range<Int>, new: Range<Int>)]

        init(_ old: [Character], _ new: [Character]) {
            oldCount = old.count
            newCount = new.count
            // 共通の先頭と末尾を先に除く（LCS の表は O(nm)）
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let middle = Self.lcs(Array(old[prefix..<(old.count - suffix)]), Array(new[prefix..<(new.count - suffix)]))
                .map { (old: $0.old + prefix, new: $0.new + prefix) }
            matches = (0..<prefix).map { (old: $0, new: $0) } + middle
                + (0..<suffix).map { (old: old.count - suffix + $0, new: new.count - suffix + $0) }
            var changes: [(old: Range<Int>, new: Range<Int>)] = []
            var previous = (old: -1, new: -1)
            for match in matches + [(old: old.count, new: new.count)] {
                if match.old > previous.old + 1 || match.new > previous.new + 1 {
                    changes.append((old: (previous.old + 1)..<match.old, new: (previous.new + 1)..<match.new))
                }
                previous = match
            }
            self.changes = changes
        }

        /// old の区間に対応する new の区間。先頭は最初の文字の相手（変わった文字ならその変更区間の new 側の先頭）、
        /// 末尾は最後の文字の相手の次（変わった文字ならその変更区間の new 側の末尾）。
        /// 区間の内側にある挿入と削除は含まれ、区間の直前・直後の挿入は含まれない（「床連れ」→「床ずれがある」で「がある」を表記に入れない）。
        func newRange(of range: Range<Int>) -> Range<Int> {
            guard !range.isEmpty else { return 0..<0 }
            let lower = matches.first { $0.old == range.lowerBound }.map(\.new)
                ?? changes.first { $0.old.contains(range.lowerBound) }?.new.lowerBound ?? newCount
            let last = range.upperBound - 1
            let upper = matches.first { $0.old == last }.map { $0.new + 1 }
                ?? changes.first { $0.old.contains(last) }?.new.upperBound ?? newCount
            return lower..<max(lower, upper)
        }

        private static func lcs(_ old: [Character], _ new: [Character]) -> [(old: Int, new: Int)] {
            var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) {
                    table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var result: [(old: Int, new: Int)] = []
            var i = 0, j = 0
            while i < old.count, j < new.count {
                if old[i] == new[j] {
                    result.append((old: i, new: j))
                    i += 1
                    j += 1
                } else if table[i + 1][j] >= table[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
            return result
        }
    }
}

/// 履歴の挿入文で、ある読みがどの表記で現れたか（ADR-10 の「足す前に、その読みを持つ別の語を普段どれだけ書くかを見る」）。
public struct ReadingUsage: Sendable, Equatable {
    /// 表記と回数。回数の多い順。
    public let surfaces: [(surface: String, count: Int)]

    public init(surfaces: [(surface: String, count: Int)]) {
        self.surfaces = surfaces
    }

    public static func == (lhs: ReadingUsage, rhs: ReadingUsage) -> Bool {
        lhs.surfaces.map(\.surface) == rhs.surfaces.map(\.surface) && lhs.surfaces.map(\.count) == rhs.surfaces.map(\.count)
    }

    public var total: Int { surfaces.reduce(0) { $0 + $1.count } }

    /// 足すと、直した表記以外の語（誤表記を正しく使った箇所を含む）も置き換わるか。
    public func collides(with surface: String) -> Bool {
        surfaces.contains { $0.surface != surface }
    }

    public static func of(reading: String, in texts: [String]) -> ReadingUsage {
        of(readings: [reading], in: texts)[reading] ?? ReadingUsage(surfaces: [])
    }

    /// 複数の読みを 1 回の走査で数える（履歴の単語分けが重いので、読みごとに走査しない）。
    public static func of(readings: [String], in texts: [String]) -> [String: ReadingUsage] {
        let readings = Array(Set(readings))
        guard !readings.isEmpty else { return [:] }
        let matcher = YomiDictionary.matcher(readings: readings)
        var counts: [String: [String: Int]] = [:]
        for text in texts {
            for match in matcher.matches(in: text) { counts[match.surface, default: [:]][match.original, default: 0] += 1 }
        }
        return Dictionary(uniqueKeysWithValues: readings.map { reading in
            let sorted = (counts[reading] ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            return (reading, ReadingUsage(surfaces: sorted.map { (surface: $0.key, count: $0.value) }))
        })
    }
}

/// 辞書ファイルへの追記（ADR-18）。行は parse に通してから書き、既存の内容は読み直さない（追記だけ）。
public enum DictionaryFile {
    public struct Row: Sendable, Equatable {
        public let surface: String
        public let reading: String

        public init(surface: String, reading: String) {
            self.surface = surface
            self.reading = reading
        }
    }

    public enum WriteError: Error, LocalizedError, Equatable {
        case notUTF8(path: String)
        case unreadableRows([String])

        public var errorDescription: String? {
            switch self {
            case .notUTF8(let path): "\(URL(filePath: path).lastPathComponent) が UTF-8 でないので、追記しませんでした。UTF-8 で保存し直してください。"
            case .unreadableRows(let reasons): reasons.joined()
            }
        }
    }

    /// 足す行を、辞書と同じ読み方（parse）で確かめる。読み飛ばされる行があれば、その理由。
    public static func problems(in rows: [Row]) -> [String] {
        rows.flatMap { row -> [String] in
            if row.surface.contains(where: { $0 == "\t" || $0.isNewline }) || row.reading.contains(where: { $0 == "\t" || $0.isNewline }) {
                return ["「\(row.surface)」にタブか改行が入っています。"]
            }
            // parse は # で始まる行をコメントとして黙って読み飛ばす
            if row.surface.hasPrefix("#") { return ["「\(row.surface)」は # で始まるので、辞書ではコメントとして読み飛ばされます。"] }
            return YomiDictionary.parse(tsv: line(of: row)).skipped.map { $0.localizedDescription.replacing(/辞書の \d+ 行目/, with: "この行") }
        }
    }

    private static func line(of row: Row) -> String { "\(row.surface)\t\(row.reading)" }

    /// 日付のコメントに続けて末尾に追記する。ファイルが無ければ作る。
    /// 既存の内容は書き直さない（文字コードが UTF-8 でなければ断る。シンボリックリンクは先をたどる）。改行コードは既存のものに合わせる。
    public static func append(_ rows: [Row], to url: URL, date: Date = .now) throws {
        let problems = problems(in: rows)
        guard problems.isEmpty else { throw WriteError.unreadableRows(problems) }
        // 無いときだけ新しく作る。読めない理由が他（権限など）なら、上書きせずに失敗させる
        let existing: Data?
        do {
            existing = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            existing = nil
        }
        var newline = "\n"
        if let existing {
            // UTF-8 の文書に NUL は現れない（BOM の無い UTF-16 を UTF-8 と誤認しないため）
            guard !existing.contains(0), let text = String(data: existing, encoding: .utf8) else { throw WriteError.notUTF8(path: url.path) }
            if text.contains("\r\n") { newline = "\r\n" }
        }
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var text = "# \(day) 「直前の発話を直して辞書に足す」から" + newline + rows.map { line(of: $0) + newline }.joined()
        if let existing, !existing.isEmpty, existing.last != 0x0A { text = newline + text }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existing == nil {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

extension Character {
    /// 漢字、カタカナ、英字。平仮名だけの語（助詞や活用語尾）や記号・数字は本文の語と見なさない。
    var isContentCharacter: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .otherLetter: !scalar.isHiragana
            default: false
            }
        }
    }

    var isHiragana: Bool { unicodeScalars.allSatisfy(\.isHiragana) }

    /// 算用数字（全角を含む）。漢数字（一、十、京）は `isNumber` が真になるので使わない。
    var isDecimalDigit: Bool { unicodeScalars.contains { $0.properties.generalCategory == .decimalNumber } }
}

extension Unicode.Scalar {
    var isHiragana: Bool { (0x3041...0x309F).contains(value) }
}
