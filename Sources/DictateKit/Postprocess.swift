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
    /// コマンドの語を除いた本文。
    public let body: String
    public let command: VoiceCommand?
}

public func postprocess(_ recognized: String, dictionary: YomiDictionary) -> Postprocessed {
    let replaced = dictionary.apply(recognized.trimmingCharacters(in: .whitespacesAndNewlines))
    let (body, command) = splitTrailingCommand(replaced.text)
    return Postprocessed(afterDictionary: replaced.text, replacements: replaced.replacements, body: body, command: command)
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
