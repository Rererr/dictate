// 標準入力の各行を「読み（ひらがな）」に変換する。漢字の読みは CFStringTokenizer のラテン転写から得る（macOS 内蔵、辞書不要）。
import Foundation
while let line = readLine() {
    let s = line as CFString
    let tok = CFStringTokenizerCreate(nil, s, CFRangeMake(0, CFStringGetLength(s)), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
    var out = ""
    var t = CFStringTokenizerAdvanceToNextToken(tok)
    while t.rawValue != 0 {
        let r = CFStringTokenizerGetCurrentTokenRange(tok)
        let word = CFStringCreateWithSubstring(nil, s, r)! as String
        if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String,
           let kana = latin.applyingTransform(.latinToHiragana, reverse: false) {
            out += kana
        } else {
            out += word
        }
        t = CFStringTokenizerAdvanceToNextToken(tok)
    }
    // カタカナはひらがなへ寄せ、長音・空白を落とす
    out = out.applyingTransform(.hiraganaToKatakana, reverse: true) ?? out
    print(out.replacingOccurrences(of: "ー", with: "").replacingOccurrences(of: " ", with: ""))
}
