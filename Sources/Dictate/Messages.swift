import DictateKit

/// 字幕とトーストに出す文言。デモ再生と実動作で同じものを使う。
/// トーストの文言は、1 文目に起きたこと、2 文目以降に次にすることを書き、どの文も句点で終える。
/// 表示の側が句点ごとに改行する。
enum Messages {
    // 字幕
    static let listening = "聞いています"
    static let finalizing = "確定中"
    static let formatting = "整形中"

    // 受け付けなかった操作
    static let busy = "前の発話を処理中です。終わってから押してください。"
    static let secureInput = "セキュア入力中のため、録音しません。パスワード欄にカーソルがあるか、他のアプリがセキュア入力を有効にしています。"
    static let microphoneDenied = "マイクの許可がありません。システム設定を開くので、プライバシーとセキュリティ > マイクで、Dictate を許可してください。"

    // 許可の付け直し
    static let accessibilityReset = "アクセシビリティの許可の記録を消しました。システム設定を開くので、一覧で Dictate をオンにしてください。"
    static func accessibilityResetFailed(_ detail: String) -> String { "許可の記録を消せませんでした（\(detail)）。ターミナルで tccutil reset Accessibility com.rererr.dictate を実行してください。" }

    // 起動時の点検
    static let modelNotInstalled = "日本語の音声認識モデルが導入されていません。システム設定 > キーボード > 音声入力で、日本語を追加してください。メニューの「音声入力の設定を開く」からも開けます。"

    // 認識
    static let noResult = "音声を認識できませんでした。キーを押している間に話してください。"

    // 挿入
    private static let recover = "メニューの「直前の発話をコピー」で取り出せます。"
    static let unverified = "挿入を確認できませんでした。入っていなければ、\(recover)"
    static let unverifiedNotSent = "挿入を確認できなかったため、送信していません。入っていれば、Return を押してください。入っていなければ、\(recover)"
    static let secureInputAtInsert = "セキュア入力中のため、挿入しません。今の発話は、\(recover)"
    static let accessibilityDenied = "アクセシビリティの許可がないため、挿入できません。システム設定を開くので、プライバシーとセキュリティ > アクセシビリティで、Dictate を許可してください。今の発話は、\(recover)"

    /// 整形を採用しなかった理由。本文は整形前のまま入っている。
    static func formatSkipped(_ status: FormatStatus) -> String? {
        switch status {
        case .adopted: nil
        case .timedOut: "整形が間に合わなかったため、整形前の文を挿入しました。"
        case .rejected: "整形の結果が検証を通らなかったため、整形前の文を挿入しました。"
        case .unreachable: "整形サーバから結果を得られなかったため、整形前の文を挿入しました。サーバが起動しているかを確認するか、メニューの「LLM で整える」をオフにしてください。"
        }
    }

    static func recognitionFailed(_ detail: String) -> String { "認識に失敗しました。\(detail)" }
    static func microphoneFailed(_ detail: String) -> String { "マイクを開けません。\(detail)" }
    static func historyFailed(_ detail: String) -> String { "履歴に書けません。\(detail)" }
    static func loadFailed(_ detail: String) -> String { "\(detail)対応してから、メニューの「設定と辞書を再読み込み」を選んでください。" }
}
