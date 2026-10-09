import Foundation

/// 読みが一致した区間を表記に置き換える。一致は単語境界に限る。
public struct YomiDictionary: Sendable {
    public struct Entry: Sendable, Equatable {
        public let surface: String
        /// 表記から読みが出ない語（英字など）だけ明示する。
        public let reading: String?

        public init(surface: String, reading: String? = nil) {
            self.surface = surface
            self.reading = reading
        }
    }

    public struct Replacement: Sendable, Equatable {
        public let original: String
        public let surface: String
    }

    public struct Replaced: Sendable, Equatable {
        public let text: String
        public let replacements: [Replacement]
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case malformedLine(number: Int, content: String)
        case emptyKey(number: Int, surface: String)

        public var errorDescription: String? {
            switch self {
            case .malformedLine(let number, let content):
                "辞書の \(number) 行目を読めません。「表記<TAB>読み」の形にしてください。該当の行は「\(content)」です。"
            case .emptyKey(let number, let surface):
                "辞書の \(number) 行目「\(surface)」から読みを作れません。読みを明示してください。"
            }
        }
    }

    private let surfaces: [String: String]
    private let longestKey: Int

    public init(entries: [Entry]) {
        var surfaces: [String: String] = [:]
        for entry in entries {
            surfaces[Self.reading(of: entry.reading ?? entry.surface)] = entry.surface
        }
        surfaces[""] = nil
        self.surfaces = surfaces
        self.longestKey = surfaces.keys.map(\.count).max() ?? 0
    }

    /// `表記<TAB>読み`（読みは省略可）。空行と `#` で始まる行は読み飛ばす。
    public init(tsv: String) throws {
        var entries: [Entry] = []
        // CRLF は Swift では 1 文字で、"\n" では分かれない。BOM は 1 行目の表記に混ざる
        let lines = tsv.trimmingPrefix("\u{FEFF}").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count <= 2, let surface = fields.first, !surface.isEmpty else {
                throw ParseError.malformedLine(number: index + 1, content: trimmed)
            }
            let reading = fields.count == 2 && !fields[1].isEmpty ? fields[1] : nil
            guard !Self.reading(of: reading ?? surface).isEmpty else {
                throw ParseError.emptyKey(number: index + 1, surface: surface)
            }
            entries.append(Entry(surface: surface, reading: reading))
        }
        self.init(entries: entries)
    }

    public var isEmpty: Bool { surfaces.isEmpty }

    public func apply(_ text: String) -> Replaced {
        guard !surfaces.isEmpty else { return Replaced(text: text, replacements: []) }
        let source = text as NSString
        let tokens = Self.tokens(of: text)
        var output = ""
        var replacements: [Replacement] = []
        var cursor = 0
        var index = 0
        while index < tokens.count {
            guard let match = longestMatch(in: tokens, from: index) else {
                index += 1
                continue
            }
            let start = tokens[index].range.location
            let end = NSMaxRange(tokens[match.last].range)
            let original = source.substring(with: NSRange(location: start, length: end - start))
            output += source.substring(with: NSRange(location: cursor, length: start - cursor))
            output += match.surface
            if original != match.surface {
                replacements.append(Replacement(original: original, surface: match.surface))
            }
            cursor = end
            index = match.last + 1
        }
        output += source.substring(from: cursor)
        return Replaced(text: output, replacements: replacements)
    }

    private func longestMatch(in tokens: [Token], from first: Int) -> (last: Int, surface: String)? {
        // 空白は読みが空なので、区間の端に含めても読みは一致してしまう。
        // 端に入れると、表記が同じでも隣の空白ごと置き換わる
        guard !tokens[first].reading.isEmpty else { return nil }
        var key = ""
        var best: (last: Int, surface: String)?
        var last = first
        while last < tokens.count {
            // 間に句読点や空白を挟む区間は一語として扱わない
            if last > first, NSMaxRange(tokens[last - 1].range) != tokens[last].range.location { break }
            key += tokens[last].reading
            if key.count > longestKey { break }
            if !tokens[last].reading.isEmpty, let surface = surfaces[key] { best = (last, surface) }
            last += 1
        }
        return best
    }

    private struct Token {
        let range: NSRange
        let reading: String
    }

    private static func tokens(of text: String) -> [Token] {
        let string = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRangeMake(0, CFStringGetLength(string)),
            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale
        )
        var tokens: [Token] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: range.location, length: range.length)
            let word = (text as NSString).substring(with: nsRange)
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            let kana = latin?.applyingTransform(.latinToHiragana, reverse: false) ?? word
            tokens.append(Token(range: nsRange, reading: normalize(kana)))
        }
        return tokens
    }

    /// 照合キーの空間。人が知っている読みではなく、トークナイザが返す読みである
    /// （「嚥下」は「えんか」になる）。辞書側も同じ関数を通して揃える。
    public static func reading(of text: String) -> String {
        tokens(of: text).map(\.reading).joined()
    }

    private static func normalize(_ kana: String) -> String {
        (kana.applyingTransform(.hiraganaToKatakana, reverse: true) ?? kana)
            .replacingOccurrences(of: "ー", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
