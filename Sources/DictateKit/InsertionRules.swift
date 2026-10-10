import Foundation

/// 挿入の後に知らせること。成功は知らせない（入力欄に文が入ること自体が合図になる）。
public enum InsertionOutcome: Equatable, Sendable {
    case silent
    /// 本文が空でコマンドも無い。フィラーだけの発話。
    case nothingToInsert
    /// 挿入を試みなかった、または入らなかった。reason が nil なら、本文なしのコマンドをアクセシビリティの許可がなくて送れなかった。
    case notInserted(reason: String?)
    /// AX が成功を返したが、入ったと確かめられなかった。sendSkipped なら「送信して」を見送った。
    case unverified(reason: String, sendSkipped: Bool)
    /// 入ったが、整形を採用しなかった。
    case formatSkipped(FormatStatus)
}

/// 挿入の経路の判断。画面も権限も使わないので、アプリ本体とテストが同じ関数を通る。
public enum InsertionRules {
    /// 送るコマンド。話したコマンドを優先し、無ければ設定で、本文のある発話のたびに改行する。
    public static func command(spoken: VoiceCommand?, newlineAfterUtterance: Bool, text: String) -> VoiceCommand? {
        spoken ?? (newlineAfterUtterance && !text.isEmpty ? .newline : nil)
    }

    /// 本文が入った、または入ったと確かめられたか。
    /// 入っていない欄に Return だけが届くと、元からあった下書きが送信される。
    public static func confirmed(_ insertion: UtteranceRecord.Insertion) -> Bool {
        insertion.method == .paste || (insertion.method == .ax && insertion.reason == nil)
    }

    /// コマンドのキーを送るか。本文なしのコマンドは、キーを送る権限（アクセシビリティ）だけで決まる。
    public static func sends(command: VoiceCommand?, text: String, insertion: UtteranceRecord.Insertion, accessibilityTrusted: Bool) -> Bool {
        command != nil && (text.isEmpty ? accessibilityTrusted : confirmed(insertion))
    }

    /// formatSkipped は、整形を試みて採用しなかったときの判定（採用したとき、試みなかったときは nil）。
    public static func outcome(
        text: String, insertion: UtteranceRecord.Insertion, command: VoiceCommand?, sends: Bool, formatSkipped: FormatStatus?
    ) -> InsertionOutcome {
        switch (insertion.method, insertion.reason) {
        case (.none, let reason?):
            return .notInserted(reason: reason)
        case (.none, nil):
            // 理由なしの none は、本文が空で挿入を試みなかったとき
            if command == nil { return .nothingToInsert }
            return sends ? .silent : .notInserted(reason: nil)
        case (.ax, let reason?):
            return .unverified(reason: reason, sendSkipped: command == .send)
        case (.ax, nil), (.paste, _):
            return formatSkipped.map(InsertionOutcome.formatSkipped) ?? .silent
        }
    }
}
