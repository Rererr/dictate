import Foundation
import SpeechCore

public enum VoiceCommand: String, Sendable, Codable, Equatable {
    /// 挿入の後に Return を送る。
    case send
    /// 挿入の後に Shift+Return を送る。
    case newline
}

public struct Postprocessed: Sendable, Equatable {
    public let afterDictionary: String
    public let replacements: [YomiDictionary.Replacement]
    /// コマンドの語とフィラーを除いた本文。
    public let body: String
    public let command: VoiceCommand?
    /// 規則で消した文字数（フィラーと、それに付く読点と空白）。0 なら何も消していない。
    public let removedFillerCharacters: Int
}

/// 辞書の置換、末尾コマンドの切り出し、ルールによるフィラーの削除の順に掛ける。
/// フィラーの削除は LLM 整形の前段で、サーバが無くても予算を超えても効く（ADR-14）。
public func postprocess(_ recognized: String, dictionary: YomiDictionary, removeFillers: Bool = true) -> Postprocessed {
    let replaced = dictionary.apply(recognized.trimmingCharacters(in: .whitespacesAndNewlines))
    let (withFillers, command) = splitTrailingCommand(replaced.text)
    let body = removeFillers ? FillerRules.remove(from: withFillers) : withFillers
    return Postprocessed(
        afterDictionary: replaced.text, replacements: replaced.replacements, body: body, command: command,
        removedFillerCharacters: removeFillers ? withFillers.count - body.count : 0
    )
}

/// 語彙だけでフィラーを消す規則。形態素解析（MeCab、Sudachi）は曖昧語を文脈で判定せず、
/// 小型 LLM も語彙ルールに及ばなかった（2026-10-10 の計測。ADR-14）。
public enum FillerRules {
    /// 文脈に別の意味が無く、どこにあっても消せる語。長い語から照合する。
    public static let unambiguous = ["えーっと", "えっと", "えーと", "ええと", "あのー", "えー"]
    /// 連体詞や副詞としても使う語（「あの人」「その件」「まあまあ」「なんか変だ」）。
    /// 文頭か句読点の直後にあり、かつ直後に読点があるときだけフィラーとみなす。
    /// 履歴 146 発話と台本 32 文で、この条件なら誤削除 0、取りこぼし 1（「あのララベルの」読点なし）。
    public static let ambiguous = ["なんか", "あの", "その", "まあ"]

    private static let comma: Set<Character> = ["、", "，", ","]
    private static let boundary: Set<Character> = ["、", "，", ",", "。", "．", ".", "！", "!", "？", "?", "\n"]
    private static let space: Set<Character> = [" ", "　"]

    /// 母音が「え」の仮名。「へえー」「ねえー」「いいえー」の「えー」は感動詞の長音で、フィラーではない。
    private static let eRow: Set<Character> = Set("えけせてねへめれげぜでべぺエケセテネヘメレゲゼデベペ")
    /// 母音が「あ」の仮名。「まあのー」のような重なりに同じ扱いをする。
    private static let aRow: Set<Character> = Set("あかさたなはまやらわがざだばぱゃアカサタナハマヤラワガザダバパャ")

    /// 直前の文字が、語の先頭の母音を伸ばした形になるなら、そこから始まる語はフィラーとして消さない。
    /// 2 文字の「えー」は語の末尾の「え」とも重なる（「いいえー」）ので、直前が仮名なら消さない。
    /// 「それでえーと明日」のように読点の無い連続は残ることになるが、本文の一部を削るよりは残す側に倒す。
    public static func canStart(_ word: String, after previous: Character?) -> Bool {
        guard let previous, let first = word.first else { return true }
        switch first {
        case "え": return !eRow.contains(previous) && !(word == "えー" && isKana(previous))
        case "あ": return !aRow.contains(previous)
        default: return true
        }
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
    }

    public static func remove(from text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var i = 0
        /// out の末尾（空白を除く）が文頭か句読点か
        func atBoundary() -> Bool {
            guard let last = out.last(where: { !space.contains($0) }) else { return true }
            return boundary.contains(last)
        }
        /// i から word が続くか
        func matches(_ word: String, at i: Int) -> Bool {
            let w = Array(word)
            return i + w.count <= chars.count && Array(chars[i..<i + w.count]) == w
        }
        /// j から空白を飛ばした位置
        func skipSpaces(_ j: Int) -> Int {
            var j = j
            while j < chars.count, space.contains(chars[j]) { j += 1 }
            return j
        }
        while i < chars.count {
            var removed = false
            for word in unambiguous where matches(word, at: i) && canStart(word, after: out.last) {
                i = consumeComma(after: i + word.count)
                removed = true
                break
            }
            if !removed, atBoundary() {
                for word in ambiguous where matches(word, at: i) {
                    let j = skipSpaces(i + word.count)
                    guard j < chars.count, comma.contains(chars[j]) else { continue }
                    i = skipSpaces(j + 1)
                    removed = true
                    break
                }
            }
            if removed {
                // 消した語の前の空白も落とす（「あの、 Laravel」→「Laravel」）
                while let last = out.last, space.contains(last) { out.removeLast() }
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)

        /// 語の直後の空白と読点を一つだけ一緒に消す。「えっと、本番」→「本番」、「えっと本番」→「本番」
        func consumeComma(after j: Int) -> Int {
            let k = skipSpaces(j)
            if k < chars.count, comma.contains(chars[k]) { return skipSpaces(k + 1) }
            return k
        }
    }
}

private let commandPhrases: [(phrase: String, command: VoiceCommand)] = [("送信して", .send), ("改行して", .newline)]
private let trailingNoise = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "、。，．！？!?,."))

/// 末尾一致だけをコマンドとして扱う。文中の同じ語は本文である。
func splitTrailingCommand(_ text: String) -> (body: String, command: VoiceCommand?) {
    let stripped = text.trimmingTrailing(trailingNoise)
    // 表記でなく読みで照合する。「改行して」は「開業して」と認識されることがある（実測）
    for (phrase, command) in commandPhrases {
        let reading = YomiDictionary.reading(of: phrase)
        guard let length = (phrase.count - 2...phrase.count + 4).first(where: { length in
            length > 0 && length <= stripped.count && YomiDictionary.reading(of: String(stripped.suffix(length))) == reading
        }) else { continue }
        // 前の文の句点は本文の一部として残し、コマンドとの区切りの読点だけ落とす
        let body = String(stripped.dropLast(length))
            .trimmingTrailing(CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "、，,")))
        return (body, command)
    }
    return (text, nil)
}

extension String {
    func trimmingTrailing(_ set: CharacterSet) -> String {
        var scalars = unicodeScalars
        while let last = scalars.last, set.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}
